-- Indexing into a concat.  The simplifier should remove the concat.
-- ==
-- input { [1,2,3] [4,5,6] 4 } output { 5 }
-- input { [1,2,3] [4,5,6] 2 } output { 3 }
-- structure { Concat 0 }

fun int main([]int as, []int bs, int i) =
  let cs = concat(as,bs)
  in cs[i]
