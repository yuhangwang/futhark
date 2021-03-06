{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
-- | This module defines a collection of simplification rules, as per
-- "Futhark.Optimise.Simplifier.Rule".  They are used in the
-- simplifier.
module Futhark.Optimise.Simplifier.Rules
  ( standardRules

  , IndexResult (..)
  )
where

import Control.Applicative
import Control.Monad
import Data.Either
import Data.Foldable (all)
import Data.List hiding (all)
import Data.Maybe
import Data.Monoid

import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet      as HS

import qualified Futhark.Analysis.SymbolTable as ST
import qualified Futhark.Analysis.UsageTable as UT
import Futhark.Analysis.DataDependencies
import Futhark.Optimise.Simplifier.ClosedForm
import Futhark.Optimise.Simplifier.Rule
import Futhark.Optimise.Simplifier.RuleM
import qualified Futhark.Analysis.AlgSimplify as AS
import qualified Futhark.Analysis.ScalExp as SE
import Futhark.Representation.AST
import Futhark.Construct
import Futhark.Transform.Substitute
import Futhark.Util

import Prelude hiding (all)

topDownRules :: (MonadBinder m, LocalScope (Lore m) m) => TopDownRules m
topDownRules = [ hoistLoopInvariantMergeVariables
               , simplifyClosedFormLoop
               , simplifKnownIterationLoop
               , simplifyRearrange
               , simplifyRotate
               , letRule simplifyBinOp
               , letRule simplifyCmpOp
               , letRule simplifyUnOp
               , letRule simplifyConvOp
               , letRule simplifyAssert
               , letRule copyScratchToScratch
               , simplifyIndexIntoReshape
               , removeEmptySplits
               , removeSingletonSplits
               , simplifyConcat
               , evaluateBranch
               , simplifyBoolBranch
               , hoistBranchInvariant
               , simplifyScalExp
               , letRule simplifyIdentityReshape
               , letRule simplifyReshapeReshape
               , letRule simplifyReshapeScratch
               , letRule improveReshape
               , removeScratchValue
               , hackilySimplifyBranch
               , removeIdentityInPlace
               , simplifyBranchContext
               , simplifyBranchResultComparison
               ]

bottomUpRules :: MonadBinder m => BottomUpRules m
bottomUpRules = [ removeRedundantMergeVariables
                , removeDeadBranchResult
                , simplifyReplicate
                , simplifyIndex
                ]

standardRules :: (MonadBinder m, LocalScope (Lore m) m) => RuleBook m
standardRules = (topDownRules, bottomUpRules)

-- This next one is tricky - it's easy enough to determine that some
-- loop result is not used after the loop, but here, we must also make
-- sure that it does not affect any other values.
--
-- I do not claim that the current implementation of this rule is
-- perfect, but it should suffice for many cases, and should never
-- generate wrong code.
removeRedundantMergeVariables :: MonadBinder m => BottomUpRule m
removeRedundantMergeVariables (_, used) (Let pat _ (DoLoop ctx val form body))
  | not $ all (explicitlyReturned . fst) val =
  let (ctx_es, val_es) = splitAt (length ctx) $ bodyResult body
      necessaryForReturned =
        findNecessaryForReturned explicitlyReturnedOrInForm
        (zip (map fst $ ctx++val) $ ctx_es++val_es) (dataDependencies body)
      resIsNecessary ((v,_), _) =
        explicitlyReturned v ||
        paramName v `HS.member` necessaryForReturned ||
        referencedInPat v ||
        referencedInForm v
      (keep_ctx, discard_ctx) =
        partition resIsNecessary $ zip ctx ctx_es
      (keep_valpart, discard_valpart) =
        partition (resIsNecessary . snd) $
        zip (patternValueElements pat) $ zip val val_es
      (keep_valpatelems, keep_val) = unzip keep_valpart
      (_discard_valpatelems, discard_val) = unzip discard_valpart
      (ctx', ctx_es') = unzip keep_ctx
      (val', val_es') = unzip keep_val
      body' = body { bodyResult = ctx_es' ++ val_es' }
      free_in_keeps = freeIn keep_valpatelems
      stillUsedContext pat_elem =
        patElemName pat_elem `HS.member`
        (free_in_keeps <>
         freeIn (filter (/=pat_elem) $ patternContextElements pat))
      pat' = pat { patternValueElements = keep_valpatelems
                 , patternContextElements =
                     filter stillUsedContext $ patternContextElements pat }
  in if ctx' ++ val' == ctx ++ val
     then cannotSimplify
     else do
       -- We can't just remove the bindings in 'discard', since the loop
       -- body may still use their names in (now-dead) expressions.
       -- Hence, we add them inside the loop, fully aware that dead-code
       -- removal will eventually get rid of them.  Some care is
       -- necessary to handle unique bindings.
       body'' <- insertBindingsM $ do
         mapM_ (uncurry letBindNames') $ dummyBindings discard_ctx
         mapM_ (uncurry letBindNames') $ dummyBindings discard_val
         return body'
       letBind_ pat' $ DoLoop ctx' val' form body''
  where pat_used = map (`UT.used` used) $ patternValueNames pat
        used_vals = map fst $ filter snd $ zip (map (paramName . fst) val) pat_used
        explicitlyReturned = flip elem used_vals . paramName
        explicitlyReturnedOrInForm p =
          explicitlyReturned p || paramName p `HS.member` freeIn form
        patAnnotNames = freeIn $ map fst $ ctx++val
        referencedInPat = (`HS.member` patAnnotNames) . paramName
        referencedInForm = (`HS.member` freeIn form) . paramName

        dummyBindings = map dummyBinding
        dummyBinding ((p,e), _)
          | unique (paramDeclType p),
            Var v <- e            = ([paramName p], PrimOp $ Copy v)
          | otherwise             = ([paramName p], PrimOp $ SubExp e)
removeRedundantMergeVariables _ _ =
  cannotSimplify

findNecessaryForReturned :: (Param attr -> Bool) -> [(Param attr, SubExp)]
                         -> HM.HashMap VName Names
                         -> Names
findNecessaryForReturned explicitlyReturned merge_and_res allDependencies =
  iterateNecessary mempty
  where iterateNecessary prev_necessary
          | necessary == prev_necessary = necessary
          | otherwise                   = iterateNecessary necessary
          where necessary = mconcat $ map dependencies returnedResultSubExps
                explicitlyReturnedOrNecessary param =
                  explicitlyReturned param || paramName param `HS.member` prev_necessary
                returnedResultSubExps =
                  map snd $ filter (explicitlyReturnedOrNecessary . fst) merge_and_res
                dependencies (Constant _) =
                  HS.empty
                dependencies (Var v)      =
                  HM.lookupDefault (HS.singleton v) v allDependencies

-- We may change the type of the loop if we hoist out a shape
-- annotation, in which case we also need to tweak the bound pattern.
hoistLoopInvariantMergeVariables :: forall m.MonadBinder m => TopDownRule m
hoistLoopInvariantMergeVariables _ (Let pat _ (DoLoop ctx val form loopbody)) =
    -- Figure out which of the elements of loopresult are
    -- loop-invariant, and hoist them out.
  case foldr checkInvariance ([], explpat, [], []) $
       zip merge res of
    ([], _, _, _) ->
      -- Nothing is invariant.
      cannotSimplify
    (invariant, explpat', merge', res') -> do
      -- We have moved something invariant out of the loop.
      let loopbody' = loopbody { bodyResult = res' }
          invariantShape :: (a, VName) -> Bool
          invariantShape (_, shapemerge) = shapemerge `elem`
                                           map (paramName . fst) merge'
          (implpat',implinvariant) = partition invariantShape implpat
          implinvariant' = [ (patElemIdent p, Var v) | (p,v) <- implinvariant ]
          implpat'' = map fst implpat'
          explpat'' = map fst explpat'
          (ctx', val') = splitAt (length implpat') merge'
      forM_ (invariant ++ implinvariant') $ \(v1,v2) ->
        letBindNames'_ [identName v1] $ PrimOp $ SubExp v2
      letBind_ (Pattern implpat'' explpat'') $
        DoLoop ctx' val' form loopbody'
  where merge = ctx ++ val
        res = bodyResult loopbody

        implpat = zip (patternContextElements pat) $
                  map paramName $ loopResultContext (map fst ctx) (map fst val)
        explpat = zip (patternValueElements pat) $
                  map (paramName . fst) val

        namesOfMergeParams = HS.fromList $ map (paramName . fst) $ ctx++val

        removeFromResult (mergeParam,mergeInit) explpat' =
          case partition ((==paramName mergeParam) . snd) explpat' of
            ([(patelem,_)], rest) ->
              (Just (patElemIdent patelem, mergeInit), rest)
            (_,      _) ->
              (Nothing, explpat')

        checkInvariance
          ((mergeParam,mergeInit), resExp)
          (invariant, explpat', merge', resExps)
          | not (unique (paramDeclType mergeParam)) || arrayRank (paramDeclType mergeParam) == 1,
            isInvariant resExp =
          let (bnd, explpat'') =
                removeFromResult (mergeParam,mergeInit) explpat'
          in (maybe id (:) bnd $ (paramIdent mergeParam, mergeInit) : invariant,
              explpat'', merge', resExps)
          where
            -- A non-unique merge variable is invariant if the corresponding
            -- subexp in the result is EITHER:
            --
            --  (0) a variable of the same name as the parameter, where
            --  all existential parameters are already known to be
            --  invariant
            isInvariant (Var v2)
              | paramName mergeParam == v2 =
                allExistentialInvariant
                (HS.fromList $ map (identName . fst) invariant) mergeParam
            --  (1) or identical to the initial value of the parameter.
            isInvariant _ = mergeInit == resExp

        checkInvariance ((mergeParam,mergeInit), resExp) (invariant, explpat', merge', resExps) =
          (invariant, explpat', (mergeParam,mergeInit):merge', resExp:resExps)

        allExistentialInvariant namesOfInvariant mergeParam =
          all (invariantOrNotMergeParam namesOfInvariant)
          (paramName mergeParam `HS.delete` freeIn mergeParam)
        invariantOrNotMergeParam namesOfInvariant name =
          not (name `HS.member` namesOfMergeParams) ||
          name `HS.member` namesOfInvariant
hoistLoopInvariantMergeVariables _ _ = cannotSimplify

-- | A function that, given a variable name, returns its definition.
type VarLookup lore = VName -> Maybe (Exp lore)

-- | A function that, given a subexpression, returns its type.
type TypeLookup = SubExp -> Maybe Type

type LetTopDownRule lore u = VarLookup lore -> TypeLookup
                             -> PrimOp lore -> Maybe (PrimOp lore)

letRule :: MonadBinder m => LetTopDownRule (Lore m) u -> TopDownRule m
letRule rule vtable (Let pat _ (PrimOp op)) =
  letBind_ pat =<< liftMaybe (PrimOp <$> rule defOf seType op)
  where defOf = (`ST.lookupExp` vtable)
        seType (Var v) = ST.lookupType v vtable
        seType (Constant v) = Just $ Prim $ primValueType v
letRule _ _ _ =
  cannotSimplify

simplifyClosedFormLoop :: MonadBinder m => TopDownRule m
simplifyClosedFormLoop _ (Let pat _ (DoLoop [] val (ForLoop i bound) body)) =
  loopClosedForm pat val (HS.singleton i) bound body
simplifyClosedFormLoop _ _ = cannotSimplify

simplifKnownIterationLoop :: forall m.MonadBinder m => TopDownRule m
simplifKnownIterationLoop _ (Let pat _
                                (DoLoop ctx val
                                 (ForLoop i (Constant (IntValue (Int32Value 1)))) body)) = do
  forM_ (ctx++val) $ \(mergevar, mergeinit) ->
    letBindNames' [paramName mergevar] $ PrimOp $ SubExp mergeinit
  letBindNames'_ [i] $ PrimOp $ SubExp $ constant (0 :: Int32)
  (loop_body_ctx, loop_body_val) <- splitAt (length ctx) <$> (mapM asVar =<< bodyBind body)
  let subst = HM.fromList $ zip (map (paramName . fst) ctx) loop_body_ctx
      ctx_params = substituteNames subst $ map fst ctx
      val_params = substituteNames subst $ map fst val
      res_context = loopResultContext ctx_params val_params
  forM_ (zip (patternContextElements pat) res_context) $ \(pat_elem, p) ->
    letBind_ (Pattern [] [pat_elem]) $ PrimOp $ SubExp $ Var $ paramName p
  forM_ (zip (patternValueElements pat) loop_body_val) $ \(pat_elem, v) ->
    letBind_ (Pattern [] [pat_elem]) $ PrimOp $ SubExp $ Var v
  where asVar (Var v)      = return v
        asVar (Constant v) = letExp "named" $ PrimOp $ SubExp $ Constant v
simplifKnownIterationLoop _ _ =
  cannotSimplify

simplifyRearrange :: MonadBinder m => TopDownRule m

-- Handle identity permutation.
simplifyRearrange _ (Let pat _ (PrimOp (Rearrange _ perm v)))
  | sort perm == perm =
      letBind_ pat $ PrimOp $ SubExp $ Var v

simplifyRearrange vtable (Let pat _ (PrimOp (Rearrange cs perm v)))
  | Just (Rearrange cs2 perm2 e) <- asPrimOp =<< ST.lookupExp v vtable =
      -- Rearranging a rearranging: compose the permutations.
      letBind_ pat $ PrimOp $ Rearrange (cs++cs2) (perm `rearrangeCompose` perm2) e

simplifyRearrange vtable (Let pat _ (PrimOp (Rearrange cs perm v)))
  | Just (Rotate cs2 offsets v2) <- asPrimOp =<< ST.lookupExp v vtable,
    Just (Rearrange cs3 perm3 v3) <- asPrimOp =<< ST.lookupExp v2 vtable = do
      let offsets' = rearrangeShape (rearrangeInverse perm3) offsets
      rearrange_rotate <- letExp "rearrange_rotate" $ PrimOp $ Rotate cs2 offsets' v3
      letBind_ pat $ PrimOp $ Rearrange (cs++cs3) (perm `rearrangeCompose` perm3) rearrange_rotate

simplifyRearrange vtable (Let pat _ (PrimOp (Rearrange cs1 perm1 v1)))
  | Just (to_drop, to_take, cs2, 0, v2) <- isDropTake v1 vtable,
    Just (Rearrange cs3 perm3 v3) <- asPrimOp =<< ST.lookupExp v2 vtable,
    dim1:_ <- perm1,
    perm1 == rearrangeInverse perm3 = do
      to_drop' <- letSubExp "drop" =<< SE.fromScalExp to_drop
      to_take' <- letSubExp "take" =<< SE.fromScalExp to_take
      [_, v] <- letTupExp' "simplify_rearrange" $
        PrimOp $ Split (cs1<>cs2<>cs3) dim1 [to_drop', to_take'] v3
      letBind_ pat $ PrimOp $ SubExp v

simplifyRearrange _ _ = cannotSimplify

isDropTake :: VName -> ST.SymbolTable lore
           -> Maybe (SE.ScalExp, SE.ScalExp,
                     Certificates, Int, VName)
isDropTake v vtable = do
  Let pat _ (PrimOp (Split cs dim splits v')) <- ST.entryBinding =<< ST.lookup v vtable
  i <- elemIndex v $ patternValueNames pat
  return (prod $ take i splits,
          prod $ take 1 $ drop i splits,
          cs, dim, v')
  where prod = product . map SE.intSubExpToScalExp

simplifyRotate :: MonadBinder m => TopDownRule m
-- A zero-rotation is identity.
simplifyRotate _ (Let pat _ (PrimOp (Rotate _ offsets v)))
  | all (==constant (0::Int32)) offsets =
      letBind_ pat $ PrimOp $ SubExp $ Var v

simplifyRotate vtable (Let pat _ (PrimOp (Rotate cs offsets v)))
  | Just (Rearrange cs2 perm v2) <- asPrimOp =<< ST.lookupExp v vtable,
    Just (Rotate cs3 offsets2 v3) <- asPrimOp =<< ST.lookupExp v2 vtable = do
      let offsets2' = rearrangeShape (rearrangeInverse perm) offsets2
          addOffsets x y = letSubExp "summed_offset" $ PrimOp $ BinOp (Add Int32) x y
      offsets' <- zipWithM addOffsets offsets offsets2'
      rotate_rearrange <- letExp "rotate_rearrange" $ PrimOp $ Rearrange cs2 perm v3
      letBind_ pat $ PrimOp $ Rotate (cs++cs3) offsets' rotate_rearrange

simplifyRotate _ _ = cannotSimplify

simplifyReplicate :: MonadBinder m => BottomUpRule m
simplifyReplicate (vtable, used) (Let pat _ (PrimOp (Replicate (Constant n) (Var v))))
  | oneIsh n,
    not $ any (`UT.isConsumed` used) $ v : patternNames pat,
    Just shape <- arrayDims <$> ST.lookupType v vtable,
    not $ null shape =
      letBind_ pat $ PrimOp $ Reshape [] (map DimNew $ constant (1::Int32) : shape) v
simplifyReplicate _ _ = cannotSimplify

simplifyCmpOp :: LetTopDownRule lore u
simplifyCmpOp _ _ (CmpOp cmp e1 e2)
  | e1 == e2 = binOpRes $ BoolValue $
               case cmp of CmpEq{}  -> True
                           CmpSlt{} -> False
                           CmpUlt{} -> False
                           CmpSle{} -> True
                           CmpUle{} -> True
                           FCmpLt{} -> False
                           FCmpLe{} -> True
simplifyCmpOp _ _ (CmpOp cmp (Constant v1) (Constant v2)) =
  binOpRes =<< BoolValue <$> doCmpOp cmp v1 v2
simplifyCmpOp _ _ _ = Nothing

simplifyBinOp :: LetTopDownRule lore u

simplifyBinOp _ _ (BinOp op (Constant v1) (Constant v2))
  | Just res <- doBinOp op v1 v2 =
      return $ SubExp $ Constant res

simplifyBinOp _ _ (BinOp Add{} e1 e2)
  | isCt0 e1 = Just $ SubExp e2
  | isCt0 e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp FAdd{} e1 e2)
  | isCt0 e1 = Just $ SubExp e2
  | isCt0 e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp Sub{} e1 e2)
  | isCt0 e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp FSub{} e1 e2)
  | isCt0 e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp Mul{} e1 e2)
  | isCt0 e1 = Just $ SubExp e1
  | isCt0 e2 = Just $ SubExp e2
  | isCt1 e1 = Just $ SubExp e2
  | isCt1 e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp FMul{} e1 e2)
  | isCt0 e1 = Just $ SubExp e1
  | isCt0 e2 = Just $ SubExp e2
  | isCt1 e1 = Just $ SubExp e2
  | isCt1 e2 = Just $ SubExp e1

simplifyBinOp look _ (BinOp (SMod t) e1 e2)
  | isCt1 e2 = Just $ SubExp e1
  | e1 == e2 = binOpRes $ IntValue $ intValue t (1 :: Int)
  | Var v1 <- e1,
    Just (PrimOp (BinOp SMod{} e3 e4)) <- look v1,
    e4 == e2 = Just $ SubExp e3

simplifyBinOp _ _ (BinOp SDiv{} e1 e2)
  | isCt0 e1 = Just $ SubExp e1
  | isCt1 e2 = Just $ SubExp e1
  | isCt0 e2 = Nothing

simplifyBinOp _ _ (BinOp (SRem t) e1 e2)
  | isCt0 e2 = Just $ SubExp e1
  | e1 == e2 = binOpRes $ IntValue $ intValue t (1 :: Int)

simplifyBinOp _ _ (BinOp SQuot{} e1 e2)
  | isCt0 e1 = Just $ SubExp e1
  | isCt1 e2 = Just $ SubExp e1
  | isCt0 e2 = Nothing

simplifyBinOp _ _ (BinOp (FPow t) e1 e2)
  | isCt0 e2 = Just $ SubExp $ floatConst t 1
  | isCt0 e1 || isCt1 e1 || isCt1 e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp (Shl t) e1 e2)
  | isCt0 e2 = Just $ SubExp e1
  | isCt0 e1 = Just $ SubExp $ intConst t 0

simplifyBinOp _ _ (BinOp AShr{} e1 e2)
  | isCt0 e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp (And t) e1 e2)
  | isCt0 e1 = Just $ SubExp $ intConst t 0
  | isCt0 e2 = Just $ SubExp $ intConst t 0
  | e1 == e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp Or{} e1 e2)
  | isCt0 e1 = Just $ SubExp e2
  | isCt0 e2 = Just $ SubExp e1
  | e1 == e2 = Just $ SubExp e1

simplifyBinOp _ _ (BinOp (Xor t) e1 e2)
  | isCt0 e1 = Just $ SubExp e2
  | isCt0 e2 = Just $ SubExp e1
  | e1 == e2 = Just $ SubExp $ intConst t 0

simplifyBinOp defOf _ (BinOp LogAnd e1 e2)
  | isCt0 e1 = Just $ SubExp $ Constant $ BoolValue False
  | isCt0 e2 = Just $ SubExp $ Constant $ BoolValue False
  | isCt1 e1 = Just $ SubExp e2
  | isCt1 e2 = Just $ SubExp e1
  | Var v <- e1,
    Just (UnOp Not e1') <- asPrimOp =<< defOf v,
    e1' == e2 = binOpRes $ BoolValue False
  | Var v <- e2,
    Just (UnOp Not e2') <- asPrimOp =<< defOf v,
    e2' == e1 = binOpRes $ BoolValue False

simplifyBinOp defOf _ (BinOp LogOr e1 e2)
  | isCt0 e1 = Just $ SubExp e2
  | isCt0 e2 = Just $ SubExp e1
  | isCt1 e1 = Just $ SubExp $ Constant $ BoolValue True
  | isCt1 e2 = Just $ SubExp $ Constant $ BoolValue True
  | Var v <- e1,
    Just (UnOp Not e1') <- asPrimOp =<< defOf v,
    e1' == e2 = binOpRes $ BoolValue True
  | Var v <- e2,
    Just (UnOp Not e2') <- asPrimOp =<< defOf v,
    e2' == e1 = binOpRes $ BoolValue True

simplifyBinOp _ _ _ = Nothing

binOpRes :: PrimValue -> Maybe (PrimOp lore)
binOpRes = Just . SubExp . Constant

simplifyUnOp :: LetTopDownRule lore u
simplifyUnOp _ _ (UnOp op (Constant v)) =
  binOpRes =<< doUnOp op v
simplifyUnOp defOf _ (UnOp Not (Var v))
  | Just (PrimOp (UnOp Not v2)) <- defOf v =
  Just $ SubExp v2
simplifyUnOp _ _ _ =
  Nothing

simplifyConvOp :: LetTopDownRule lore u
simplifyConvOp _ _ (ConvOp op (Constant v)) =
  binOpRes =<< doConvOp op v
simplifyConvOp _ _ (ConvOp op se)
  | (from, to) <- convTypes op, from == to =
  Just $ SubExp se
simplifyConvOp _ _ _ =
  Nothing

-- If expression is true then just replace assertion.
simplifyAssert :: LetTopDownRule lore u
simplifyAssert _ _ (Assert (Constant (BoolValue True)) _) =
  Just $ SubExp $ Constant Checked
simplifyAssert _ _ _ =
  Nothing

simplifyIndex :: MonadBinder m => BottomUpRule m
simplifyIndex (vtable, used) (Let pat@(Pattern [] [pe]) _ (PrimOp (Index cs idd inds)))
  | Just m <- simplifyIndexing vtable seType idd inds consumed = do
      res <- m
      case res of
        SubExpResult se ->
          letBind_ pat $ PrimOp $ SubExp se
        IndexResult extra_cs idd' inds' ->
          letBind_ pat $ PrimOp $ Index (cs++extra_cs) idd' inds'
  where consumed = patElemName pe `UT.isConsumed` used
        seType (Var v) = ST.lookupType v vtable
        seType (Constant v) = Just $ Prim $ primValueType v

simplifyIndex _ _ = cannotSimplify

data IndexResult = IndexResult Certificates VName [SubExp]
                 | SubExpResult SubExp

simplifyIndexing :: MonadBinder m =>
                    ST.SymbolTable lore -> TypeLookup
                 -> VName -> [SubExp] -> Bool
                 -> Maybe (m IndexResult)
simplifyIndexing vtable seType idd inds consuming =
  case asPrimOp =<< defOf idd of
    Nothing -> Nothing

    Just (SubExp (Var v)) -> Just $ pure $ IndexResult [] v inds

    Just (Iota _ (Constant (IntValue (Int32Value 0))) (Constant (IntValue (Int32Value 1))))
      | [ii] <- inds ->
          Just $ pure $ SubExpResult ii

    Just (Iota _ x s)
      | [ii] <- inds ->
          Just $
          fmap SubExpResult $ letSubExp "index_iota" <=< SE.fromScalExp $
          SE.intSubExpToScalExp ii * SE.intSubExpToScalExp s +
          SE.intSubExpToScalExp x

    Just (Rotate cs offsets a)
      | length offsets == length inds -> Just $ do
          dims <- arrayDims <$> lookupType a
          let adjust (i, o, d) = do
                i_m_o <- letSubExp "i_p_o" $ PrimOp $ BinOp (Add Int32) i o
                letSubExp "rot_i" $ PrimOp $ BinOp (SMod Int32) i_m_o d
          inds' <- mapM adjust $ zip3 inds offsets dims
          pure $ IndexResult cs a inds'

    Just (Index cs aa ais) ->
      Just $ pure $ IndexResult cs aa (ais ++ inds)

    Just (Replicate _ (Var vv))
      | [_]   <- inds, not consuming -> Just $ pure $ SubExpResult $ Var vv
      | _:is' <- inds, not consuming -> Just $ pure $ IndexResult [] vv is'

    Just (Replicate _ val@(Constant _))
      | [_] <- inds, not consuming -> Just $ pure $ SubExpResult val

    Just (Rearrange cs perm src)
       | rearrangeReach perm <= length inds ->
         let inds' = rearrangeShape (take (length inds) $ rearrangeInverse perm) inds
         in Just $ pure $ IndexResult cs src inds'

    Just (Copy src)
      -- We cannot just remove a copy of a rearrange, because it might
      -- be important for coalescing.
      | Just (PrimOp Rearrange{}) <- defOf src ->
          Nothing
      | Just dims <- arrayDims <$> seType (Var src),
        length inds == length dims,
        not consuming ->
          Just $ pure $ IndexResult [] src inds

    Just (Reshape cs newshape src)
      | Just newdims <- shapeCoercion newshape,
        Just olddims <- arrayDims <$> seType (Var src),
        changed_dims <- zipWith (/=) newdims olddims,
        not $ or $ drop (length inds) changed_dims ->
        Just $ pure $ IndexResult cs src inds

      | Just newdims <- shapeCoercion newshape,
        Just olddims <- arrayDims <$> seType (Var src),
        length newshape == length inds,
        length olddims == length newdims ->
        Just $ pure $ IndexResult cs src inds

    Just (Reshape cs [_] v2)
      | Just [_] <- arrayDims <$> seType (Var v2) ->
        Just $ pure $ IndexResult cs v2 inds

    Just (Concat cs d x xs _) | Just (ibef, i, iaft) <- focusNth d inds -> Just $ do
      res_t <- stripArray (length inds) <$> lookupType x
      x_len <- arraySize d <$> lookupType x
      xs_lens <- mapM (fmap (arraySize d) . lookupType) xs

      let add n m = do
            added <- letSubExp "index_concat_add" $ PrimOp $ BinOp (Add Int32) n m
            return (added, n)
      (_, starts) <- mapAccumLM add x_len xs_lens
      let xs_and_starts = zip (reverse xs) starts

      let mkBranch [] =
            letSubExp "index_concat" $ PrimOp $ Index cs x (ibef++i:iaft)
          mkBranch ((x', start):xs_and_starts') = do
            cmp <- letSubExp "index_concat_cmp" $ PrimOp $ CmpOp (CmpSle Int32) start i
            (thisres, thisbnds) <- collectBindings $ do
              i' <- letSubExp "index_concat_i" $ PrimOp $ BinOp (Sub Int32) i start
              letSubExp "index_concat" $ PrimOp $ Index cs x' (ibef++i':iaft)
            thisbody <- mkBodyM thisbnds [thisres]
            (altres, altbnds) <- collectBindings $ mkBranch xs_and_starts'
            altbody <- mkBodyM altbnds [altres]
            letSubExp "index_concat_branch" $ If cmp thisbody altbody $ staticShapes [res_t]
      SubExpResult <$> mkBranch xs_and_starts

    Just (ArrayLit ses _)
      | Constant (IntValue (Int32Value i)) : inds' <- inds,
        Just se <- maybeNth i ses ->
        case inds' of
          [] -> Just $ pure $ SubExpResult se
          _ | Var v2 <- se  -> Just $ pure $ IndexResult [] v2 inds'
          _ -> Nothing

    _ -> case ST.entryBinding =<< ST.lookup idd vtable of
           Just (Let split_pat _ (PrimOp (Split cs2 0 ns idd2)))
             | first_index : rest_indices <- inds -> Just $ do
               -- Figure out the extra offset that we should add to the first index.
               let plus = eBinOp (Add Int32)
                   esum [] = return $ PrimOp $ SubExp $ constant (0 :: Int32)
                   esum (x:xs) = foldl plus x xs

               patElem_and_offset <-
                 zip (patternValueElements split_pat) <$>
                 mapM esum (inits $ map eSubExp ns)
               case find ((==idd) . patElemName . fst) patElem_and_offset of
                 Nothing ->
                   fail "simplifyIndexing: could not find pattern element."
                 Just (_, offset_e) -> do
                   offset <- letSubExp "offset" offset_e
                   offset_index <- letSubExp "offset_index" $
                                   PrimOp $ BinOp (Add Int32) first_index offset
                   return $ IndexResult cs2 idd2 (offset_index:rest_indices)
           _ -> Nothing

    where defOf = (`ST.lookupExp` vtable)

simplifyIndexIntoReshape :: MonadBinder m => TopDownRule m
simplifyIndexIntoReshape vtable (Let pat _ (PrimOp (Index cs idd inds)))
  | Just (Reshape cs2 newshape idd2) <- asPrimOp =<< ST.lookupExp idd vtable,
    length newshape == length inds =
      case shapeCoercion newshape of
        Just _ ->
          letBind_ pat $ PrimOp $ Index (cs++cs2) idd2 inds
        Nothing -> do
          -- Linearise indices and map to old index space.
          oldshape <- arrayDims <$> lookupType idd2
          let new_inds =
                reshapeIndex (map SE.intSubExpToScalExp oldshape)
                             (map SE.intSubExpToScalExp $ newDims newshape)
                             (map SE.intSubExpToScalExp inds)
          new_inds' <-
            mapM (letSubExp "new_index" <=< SE.fromScalExp) new_inds
          letBind_ pat $ PrimOp $ Index (cs++cs2) idd2 new_inds'
simplifyIndexIntoReshape _ _ =
  cannotSimplify

removeEmptySplits :: MonadBinder m => TopDownRule m
removeEmptySplits _ (Let pat _ (PrimOp (Split cs i ns arr)))
  | (pointless,sane) <- partition (isCt0 . snd) $ zip (patternValueElements pat) ns,
    not (null pointless) = do
      rt <- rowType <$> lookupType arr
      letBind_ (Pattern [] $ map fst sane) $
        PrimOp $ Split cs i (map snd sane) arr
      forM_ pointless $ \(patElem,_) ->
        letBindNames' [patElemName patElem] $
        PrimOp $ ArrayLit [] rt
removeEmptySplits _ _ =
  cannotSimplify

removeSingletonSplits :: MonadBinder m => TopDownRule m
removeSingletonSplits _ (Let pat _ (PrimOp (Split _ _ [n] arr))) = do
  size <- arraySize 0 <$> lookupType arr
  if size == n then
    letBind_ pat $ PrimOp $ SubExp $ Var arr
    else cannotSimplify
removeSingletonSplits _ _ =
  cannotSimplify

simplifyConcat :: MonadBinder m => TopDownRule m

-- concat@1(transpose(x),transpose(y)) == transpose(concat@0(x,y))
simplifyConcat vtable (Let pat _ (PrimOp (Concat cs i x xs new_d)))
  | Just r <- arrayRank <$> ST.lookupType x vtable,
    let perm = [i] ++ [0..i-1] ++ [i+1..r-1],
    Just (x',x_cs) <- transposedBy perm x,
    Just (xs',xs_cs) <- unzip <$> mapM (transposedBy perm) xs = do
      concat_rearrange <-
        letExp "concat_rearrange" $ PrimOp $
        Concat (cs++x_cs++concat xs_cs) 0 x' xs' new_d
      letBind_ pat $ PrimOp $ Rearrange [] perm concat_rearrange
  where transposedBy perm1 v =
          case ST.lookupExp v vtable of
            Just (PrimOp (Rearrange vcs perm2 v'))
              | perm1 == perm2 -> Just (v', vcs)
            _ -> Nothing
simplifyConcat _ _ =
  cannotSimplify

evaluateBranch :: MonadBinder m => TopDownRule m
evaluateBranch _ (Let pat _ (If e1 tb fb t))
  | Just branch <- checkBranch = do
  let ses = bodyResult branch
  mapM_ addBinding $ bodyBindings branch
  ctx <- subExpShapeContext t ses
  let ses' = ctx ++ ses
  sequence_ [ letBind (Pattern [] [p]) $ PrimOp $ SubExp se
            | (p,se) <- zip (patternElements pat) ses']
  where checkBranch
          | isCt1 e1  = Just tb
          | isCt0 e1  = Just fb
          | otherwise = Nothing
evaluateBranch _ _ = cannotSimplify

-- IMPROVE: This rule can be generalised to work in more cases,
-- especially when the branches have bindings, or return more than one
-- value.
simplifyBoolBranch :: MonadBinder m => TopDownRule m
-- if c then True else False == c
simplifyBoolBranch _
  (Let pat _
   (If cond
    (Body _ [] [Constant (BoolValue True)])
    (Body _ [] [Constant (BoolValue False)])
    _)) =
  letBind_ pat $ PrimOp $ SubExp cond
-- When seType(x)==bool, if c then x else y == (c && x) || (!c && y)
simplifyBoolBranch _ (Let pat _ (If cond tb fb ts))
  | Body _ [] [tres] <- tb,
    Body _ [] [fres] <- fb,
    patternSize pat == length ts,
    all (==Prim Bool) ts = do
  e <- eBinOp LogOr (pure $ PrimOp $ BinOp LogAnd cond tres)
                    (eBinOp LogAnd (pure $ PrimOp $ UnOp Not cond)
                     (pure $ PrimOp $ SubExp fres))
  letBind_ pat e
simplifyBoolBranch _ _ = cannotSimplify

-- XXX: this is a nasty ad-hoc rule for handling a pattern that occurs
-- due to limitations in shape analysis.  A better way would be proper
-- control flow analysis.
--
-- XXX: another hack is due to missing CSE.
hackilySimplifyBranch :: MonadBinder m => TopDownRule m
hackilySimplifyBranch vtable
  (Let pat _
   (If (Var cond_a)
    (Body _ [] [se1_a])
    (Body _ [] [Var v])
    _))
  | Just (If (Var cond_b)
           (Body _ [] [se1_b])
           (Body _ [] [_])
           _) <- ST.lookupExp v vtable,
    let cond_a_e = ST.lookupExp cond_a vtable,
    let cond_b_e = ST.lookupExp cond_b vtable,
    se1_a == se1_b,
    cond_a == cond_b ||
    (isJust cond_a_e && cond_a_e == cond_b_e) =
      letBind_ pat $ PrimOp $ SubExp $ Var v
hackilySimplifyBranch _ _ =
  cannotSimplify

hoistBranchInvariant :: MonadBinder m => TopDownRule m
hoistBranchInvariant _ (Let pat _ (If e1 tb fb ret))
  | patternSize pat == length ret = do
  let tses = bodyResult tb
      fses = bodyResult fb
  (pat', res, invariant) <-
    foldM branchInvariant ([], [], False) $
    zip (patternElements pat) (zip tses fses)
  let (tses', fses') = unzip res
      tb' = tb { bodyResult = tses' }
      fb' = fb { bodyResult = fses' }
  if invariant -- Was something hoisted?
     then letBind_ (Pattern [] pat') =<<
          eIf (eSubExp e1) (pure tb') (pure fb')
     else cannotSimplify
  where branchInvariant (pat', res, invariant) (v, (tse, fse))
          | tse == fse = do
            letBind_ (Pattern [] [v]) $ PrimOp $ SubExp tse
            return (pat', res, True)
          | otherwise  =
            return (v:pat', (tse,fse):res, invariant)
hoistBranchInvariant _ _ = cannotSimplify

-- | Non-existentialise the parts of the context that are the same in
-- both branches.
simplifyBranchContext :: MonadBinder m => TopDownRule m
simplifyBranchContext _ (Let pat _ e@(If cond tbranch fbranch _))
  | not $ null $ patternContextElements pat = do
      ctx_res <- expContext pat e
      let old_ctx =
            patternContextElements pat
          (free_ctx, new_ctx) =
            partitionEithers $
            zipWith ctxPatElemIsKnown old_ctx ctx_res
      if null free_ctx then
        cannotSimplify
        else do let subst =
                      HM.fromList [ (patElemName pe, v) | (pe, Var v) <- free_ctx ]
                    ret' = existentialiseExtTypes
                           (HS.fromList $ map patElemName new_ctx) $
                           substituteNames subst $
                           staticShapes $ patternValueTypes pat
                    pat' = (substituteNames subst pat) { patternContextElements = new_ctx }
                forM_ free_ctx $ \(name, se) ->
                  letBind_ (Pattern [] [name]) $ PrimOp $ SubExp se
                letBind_ pat' $ If cond tbranch fbranch ret'
  where ctxPatElemIsKnown patElem (Just se) =
          Left (patElem, se)
        ctxPatElemIsKnown patElem _ =
          Right patElem
simplifyBranchContext _ _ =
  cannotSimplify

simplifyScalExp :: MonadBinder m => TopDownRule m
simplifyScalExp vtable (Let pat _ e) = do
  res <- SE.toScalExp (`ST.lookupScalExp` vtable) e
  case res of
    -- If the sufficient condition is 'True', then it statically succeeds.
    Just se@(SE.RelExp SE.LTH0 _)
      | Right (SE.Val (BoolValue True)) <- mkDisj <$> AS.mkSuffConds se ranges ->
        letBind_ pat $ PrimOp $ SubExp $ Constant $ BoolValue True
      | SE.Val val <- AS.simplify se ranges ->
        letBind_ pat $ PrimOp $ SubExp $ Constant val
    Just se@(SE.RelExp SE.LEQ0 x)
      | let se' = SE.RelExp SE.LTH0 $ x - 1,
        Right (SE.Val (BoolValue True)) <- mkDisj <$> AS.mkSuffConds se' ranges ->
        letBind_ pat $ PrimOp $ SubExp $ Constant $ BoolValue True
      | SE.Val val <- AS.simplify se ranges ->
        letBind_ pat $ PrimOp $ SubExp $ Constant val
    _ -> cannotSimplify
  where ranges = ST.rangesRep vtable
        mkDisj []     = SE.Val $ BoolValue False
        mkDisj (x:xs) = foldl SE.SLogOr (mkConj x) $ map mkConj xs
        mkConj []     = SE.Val $ BoolValue True
        mkConj (x:xs) = foldl SE.SLogAnd x xs

simplifyIdentityReshape :: LetTopDownRule lore u
simplifyIdentityReshape _ seType (Reshape _ newshape v)
  | Just t <- seType $ Var v,
    newDims newshape == arrayDims t = -- No-op reshape.
    Just $ SubExp $ Var v
simplifyIdentityReshape _ _ _ = Nothing

simplifyReshapeReshape :: LetTopDownRule lore u
simplifyReshapeReshape defOf _ (Reshape cs newshape v)
  | Just (Reshape cs2 oldshape v2) <- asPrimOp =<< defOf v =
    Just $ Reshape (cs++cs2) (fuseReshape oldshape newshape) v2
simplifyReshapeReshape _ _ _ = Nothing

simplifyReshapeScratch :: LetTopDownRule lore u
simplifyReshapeScratch defOf _ (Reshape _ newshape v)
  | Just (Scratch bt _) <- asPrimOp =<< defOf v =
    Just $ Scratch bt $ newDims newshape
simplifyReshapeScratch _ _ _ = Nothing

improveReshape :: LetTopDownRule lore u
improveReshape _ seType (Reshape cs newshape v)
  | Just t <- seType $ Var v,
    newshape' <- informReshape (arrayDims t) newshape,
    newshape' /= newshape =
      Just $ Reshape cs newshape' v
improveReshape _ _ _ = Nothing

-- | If we are copying a scratch array (possibly indirectly), just turn it into a scratch by
-- itself.
copyScratchToScratch :: LetTopDownRule lore u
copyScratchToScratch defOf seType (Copy src) = do
  t <- seType $ Var src
  if isActuallyScratch src then
    Just $ Scratch (elemType t) (arrayDims t)
    else Nothing
  where isActuallyScratch v =
          case asPrimOp =<< defOf v of
            Just Scratch{} -> True
            Just (Rearrange _ _ v') -> isActuallyScratch v'
            Just (Reshape _ _ v') -> isActuallyScratch v'
            _ -> False
copyScratchToScratch _ _ _ =
  Nothing

removeIdentityInPlace :: MonadBinder m => TopDownRule m
removeIdentityInPlace vtable (Let (Pattern [] [d]) _ e)
  | BindInPlace _ dest destis <- patElemBindage d,
    arrayFrom e dest destis =
    letBind_ (Pattern [] [d { patElemBindage = BindVar}]) $ PrimOp $ SubExp $ Var dest
  where arrayFrom (PrimOp (Copy v)) dest destis
          | Just e' <- ST.lookupExp v vtable =
              arrayFrom e' dest destis
        arrayFrom (PrimOp (Index _ src srcis)) dest destis =
          src == dest && destis == srcis
        arrayFrom _ _ _ =
          False
removeIdentityInPlace _ _ =
  cannotSimplify

removeScratchValue :: MonadBinder m => TopDownRule m
removeScratchValue _ (Let
                      (Pattern [] [PatElem v (BindInPlace _ src _) _])
                      _
                      (PrimOp Scratch{})) =
    letBindNames'_ [v] $ PrimOp $ SubExp $ Var src
removeScratchValue _ _ =
  cannotSimplify

-- | Remove the return values of a branch, that are not actually used
-- after a branch.  Standard dead code removal can remove the branch
-- if *none* of the return values are used, but this rule is more
-- precise.
removeDeadBranchResult :: MonadBinder m => BottomUpRule m
removeDeadBranchResult (_, used) (Let pat _ (If e1 tb fb rettype))
  | -- Only if there is no existential context...
    patternSize pat == length rettype,
    -- Figure out which of the names in 'pat' are used...
    patused <- map (`UT.used` used) $ patternNames pat,
    -- If they are not all used, then this rule applies.
    not (and patused) =
  -- Remove the parts of the branch-results that correspond to dead
  -- return value bindings.  Note that this leaves dead code in the
  -- branch bodies, but that will be removed later.
  let tses = bodyResult tb
      fses = bodyResult fb
      pick = map snd . filter fst . zip patused
      tb' = tb { bodyResult = pick tses }
      fb' = fb { bodyResult = pick fses }
      pat' = pick $ patternElements pat
  in letBind_ (Pattern [] pat') =<<
     eIf (eSubExp e1) (pure tb') (pure fb')
removeDeadBranchResult _ _ = cannotSimplify

-- | If we are comparing X against the result of a branch of the form
-- @if P then Y else Z@ then replace comparison with '(P && X == Y) ||
-- (!P && X == Z').  This may allow us to get rid of a branch, and the
-- extra comparisons may be constant-folded out.  Question: maybe we
-- should have some more checks to ensure that we only do this if that
-- is actually the case, such as if we will obtain at least one
-- constant-to-constant comparison?
simplifyBranchResultComparison :: MonadBinder m => TopDownRule m
simplifyBranchResultComparison vtable (Let pat _ (PrimOp (CmpOp (CmpEq t) se1 se2)))
  | Just m <- simplifyWith se1 se2 = m
  | Just m <- simplifyWith se2 se1 = m
  where simplifyWith (Var v) x
          | Just bnd <- ST.entryBinding =<< ST.lookup v vtable,
            If p tbranch fbranch _ <- bindingExp bnd,
            Just (y, z) <-
              returns v (bindingPattern bnd) tbranch fbranch,
            HS.null $ freeIn y `HS.intersection` boundInBody tbranch,
            HS.null $ freeIn z `HS.intersection` boundInBody fbranch = Just $ do
                eq_x_y <-
                  letSubExp "eq_x_y" $ PrimOp $ CmpOp (CmpEq t) x y
                eq_x_z <-
                  letSubExp "eq_x_z" $ PrimOp $ CmpOp (CmpEq t) x z
                p_and_eq_x_y <-
                  letSubExp "p_and_eq_x_y" $ PrimOp $ BinOp LogAnd p eq_x_y
                not_p <-
                  letSubExp "not_p" $ PrimOp $ UnOp Not p
                not_p_and_eq_x_z <-
                  letSubExp "p_and_eq_x_y" $ PrimOp $ BinOp LogAnd not_p eq_x_z
                letBind_ pat $
                  PrimOp $ BinOp LogOr p_and_eq_x_y not_p_and_eq_x_z
        simplifyWith _ _ =
          Nothing

        returns v ifpat tbranch fbranch =
          fmap snd $
          find ((==v) . patElemName . fst) $
          zip (patternValueElements ifpat) $
          zip (bodyResult tbranch) (bodyResult fbranch)

simplifyBranchResultComparison _ _ =
  cannotSimplify

-- Some helper functions

isCt1 :: SubExp -> Bool
isCt1 (Constant v) = oneIsh v
isCt1 _ = False

isCt0 :: SubExp -> Bool
isCt0 (Constant v) = zeroIsh v
isCt0 _ = False
