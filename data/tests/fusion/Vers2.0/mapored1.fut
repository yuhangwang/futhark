-- ==
-- input {
--   [1.0,-4.0,-2.4]
-- }
-- output {
--   (
--     3.6
--   , [12.0, -3.0, 1.8000000000000003]
--   , [40.0, 15.0, 23.0]
--   , [0.7, -2.8, -1.68]
--   )
-- }
-- structure { 
--      Redomap 1 
-- }
--
fun (f64,[]f64,[]f64,[]f64) main([]f64 arr) =
    let a = map(+3.0, arr)   in
    let b = map(+7.0, arr)   in
    let s = reduce(+,0.0, a) in

    let x1 = map(*3.0, a)    in
    let x2 = map(*5.0, b)    in
    let x3 = map(*0.7, arr)  in

    (s,x1,x2,x3)
