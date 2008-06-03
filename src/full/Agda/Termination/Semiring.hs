-- | Semirings.

module Agda.Termination.Semiring
  ( Semiring(..)
  , semiringInvariant
  , integerSemiring
  , boolSemiring
  , Agda.Termination.Semiring.tests
  ) where

import Test.QuickCheck
import Agda.Utils.TestHelpers

-- | Semirings.

data Semiring a
  = Semiring { add  :: a -> a -> a  -- ^ Addition.
             , mul  :: a -> a -> a  -- ^ Multiplication.
             , zero :: a            -- ^ Zero.
             , one  :: a            -- ^ One.
             }

-- | Semiring invariant.

-- I think it's OK to use the same x, y, z triple for all the
-- properties below.

semiringInvariant :: (Arbitrary a, Eq a, Show a)
                  => Semiring a
                  -> a -> a -> a -> Bool
semiringInvariant (Semiring { add = (+), mul = (*)
                            , zero = zero, one = one}) = \x y z ->
  associative (+)           x y z &&
  identity zero (+)         x     &&
  commutative (+)           x y   &&
  associative (*)           x y z &&
  identity one (*)          x     &&
  leftDistributive (*) (+)  x y z &&
  rightDistributive (*) (+) x y z &&
  isZero zero (*)           x

------------------------------------------------------------------------
-- Specific semirings

-- | The standard semiring on 'Integer's.

integerSemiring :: Semiring Integer
integerSemiring = Semiring { add = (+), mul = (*), zero = 0, one = 1 }

prop_integerSemiring = semiringInvariant integerSemiring

-- | The standard semiring on 'Bool's.

boolSemiring :: Semiring Bool
boolSemiring =
  Semiring { add = (||), mul = (&&), zero = False, one = True }

prop_boolSemiring = semiringInvariant boolSemiring

------------------------------------------------------------------------
-- All tests

tests = do
  quickCheck prop_integerSemiring
  quickCheck prop_boolSemiring