-- ==
-- input {
--   10 21
-- }
-- output {
--   6
-- }

type t = int
struct NumLib  {
    fun t plus(t a, t b) = a + b
  struct BestNumbers  
    {
      fun t four() = 4
      fun t seven() = 42
      fun t six() = 41
    }
  }


fun int localplus(int a, int b) = NumLib.plus (a,b)

fun int main(int a, int b) =
  localplus(NumLib.BestNumbers.four() ,   2)
