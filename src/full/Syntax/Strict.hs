{-# OPTIONS -cpp #-}

module Syntax.Strict where

import Data.Generics

import Syntax.Common
import Syntax.Internal
import Syntax.Parser.Tokens
import qualified Syntax.Concrete as C
import qualified Syntax.Concrete.Definitions as C

#include "../undefined.h"
import Utils.Impossible

class Strict a where
    force :: a -> Int

instance Strict Term where
    force t = case ignoreBlocking t of
	Var _ ts   -> force ts
	Def _ ts   -> force ts
	Con _ ts   -> force ts
	Lam _ t    -> force t
	Lit _	   -> 0
	Pi a b	   -> force (a,b)
	Fun a b    -> force (a,b)
	Sort s	   -> force s
	MetaV _ ts -> force ts
	BlockedV _ -> __IMPOSSIBLE__

instance Strict Type where
    force (El s t) = force (s,t)

instance Strict Sort where
    force s = case s of
	Type n	  -> fromIntegral n
	Prop	  -> 0
	Lub s1 s2 -> force (s1,s2)
	Suc s	  -> force s
	MetaS _   -> 0

instance Strict ClauseBody where
    force (Body t)   = force t
    force (Bind b)   = force b
    force (NoBind b) = force b
    force  NoBody    = 0

instance Strict C.Expr where
    force e = everything (+) (const 1) e

instance Strict C.Declaration where
    force e = everything (+) (const 1) e

instance Strict C.Pragma where
    force e = everything (+) (const 1) e

instance Strict C.NiceDeclaration where
    force d = everything (+) (const 1) d

instance (Strict a, Strict b) => Strict (a,b) where
    force (x,y) = force x + force y

instance Strict a => Strict (Arg a) where
    force = force . unArg

instance Strict a => Strict [a] where
    force = sum . map force

instance Strict a => Strict (Abs a) where
    force = force . absBody

instance Strict Token where
  -- TODO: This is just a dummy instance. Why can't we just use the
  -- NFData derivation provided by Drift?
  force = (`seq` 0)

infixr 0 $!!

($!!) :: Strict a => (a -> b) -> a -> b
f $!! x = force x `seq` f x

strict :: Strict a => a -> a
strict x = id $!! x

