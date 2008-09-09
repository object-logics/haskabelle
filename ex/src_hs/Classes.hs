module Classes where

import Nats

class Monoid a where
    nothing :: a
    plus :: a -> a -> a


instance Monoid Nat where
  nothing = Zero_nat
  plus = plus_nat

summ :: (Monoid a) => [a] -> a
summ [] = nothing
summ (x:xs) = plus x (summ xs)

class (Monoid a) => Group a where
    inverse :: a -> a

instance Group Integer where
    inverse = negate

-- pow :: (Group a) => Integer -> a -> a
-- pow 0 _ = nothing
-- pow k x = if k < 0 then pow (- k) (inverse x)
--   else plus x (pow (k - 1) x)