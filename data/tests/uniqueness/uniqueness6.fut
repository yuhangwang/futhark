-- ==
-- input {
--   [1,2,3]
-- }
-- output {
--   [1,2,3]
-- }
fun []int main( [n]int  arr) =
  let  newarr  =
       (let notused  = arr
        in copy(replicate(n , 0)))
  let newarr[0] = 0 in
  arr
