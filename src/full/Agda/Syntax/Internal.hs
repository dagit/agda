{-# LANGUAGE CPP, DeriveDataTypeable, GeneralizedNewtypeDeriving #-}

module Agda.Syntax.Internal
    ( module Agda.Syntax.Internal
    , module Agda.Syntax.Abstract.Name
    ) where

import Prelude hiding (foldr)
import Control.Applicative
import Data.Generics
import Data.Foldable
import Data.Traversable

import Agda.Syntax.Position
import Agda.Syntax.Common
import Agda.Syntax.Literal
import Agda.Syntax.Abstract.Name

import Agda.Utils.Monad
import Agda.Utils.Size
import Agda.Utils.Permutation

#include "../undefined.h"
import Agda.Utils.Impossible

-- | Raw values.
--
--   @Def@ is used for both defined and undefined constants.
--   Assume there is a type declaration and a definition for
--     every constant, even if the definition is an empty
--     list of clauses.
--
data Term = Var Nat Args
	  | Lam Hiding (Abs Term)   -- ^ terms are beta normal
	  | Lit Literal
	  | Def QName Args
	  | Con QName Args
	  | Pi (Arg Type) (Abs Type)
	  | Fun (Arg Type) Type
	  | Sort Sort
	  | MetaV MetaId Args
  deriving (Typeable, Data, Eq, Show)

data Type = El Sort Term
  deriving (Typeable, Data, Eq, Show)

data Sort = Type Term   -- A term of type Nat
	  | Prop
	  | Lub Sort Sort
	  | Suc Sort
	  | MetaS MetaId Args
          | Inf
          | DLub Sort (Abs Sort)
            -- ^ if the free variable occurs in the second sort
            --   the whole thing should reduce to Inf, otherwise
            --   it's the normal Lub
  deriving (Typeable, Data, Eq, Show)

-- | Something where a meta variable may block reduction.
data Blocked t = Blocked MetaId t
               | NotBlocked t
    deriving (Typeable, Data, Eq)

instance Show t => Show (Blocked t) where
  showsPrec p (Blocked m x) = showParen (p > 0) $
    showString "Blocked " . shows m . showString " " . showsPrec 10 x
  showsPrec p (NotBlocked x) = showsPrec p x

instance Functor Blocked where
  fmap f (Blocked m t) = Blocked m $ f t
  fmap f (NotBlocked t) = NotBlocked $ f t

instance Foldable Blocked where
  foldr f z (Blocked _ x) = f x z
  foldr f z (NotBlocked x) = f x z

instance Traversable Blocked where
  traverse f (Blocked m t)  = Blocked m <$> f t
  traverse f (NotBlocked t) = NotBlocked <$> f t

instance Applicative Blocked where
  pure = notBlocked
  Blocked x f  <*> e = Blocked x $ f (ignoreBlocking e)
  NotBlocked f <*> e = f <$> e

instance Sized Term where
  size v = case v of
    Var _ vs   -> 1 + Prelude.sum (map size vs)
    Def _ vs   -> 1 + Prelude.sum (map size vs)
    Con _ vs   -> 1 + Prelude.sum (map size vs)
    MetaV _ vs -> 1 + Prelude.sum (map size vs)
    Lam _ f    -> 1 + size f
    Lit _      -> 1
    Pi a b     -> 1 + size a + size b
    Fun a b    -> 1 + size a + size b
    Sort s     -> 1

instance Sized Type where
  size = size . unEl

instance KillRange Term where
  killRange v = case v of
    Var i vs   -> killRange1 (Var i) vs
    Def c vs   -> killRange2 Def c vs
    Con c vs   -> killRange2 Con c vs
    MetaV m vs -> killRange1 (MetaV m) vs
    Lam h f    -> killRange2 Lam h f
    Lit l      -> killRange1 Lit l
    Pi a b     -> killRange2 Pi a b
    Fun a b    -> killRange2 Fun a b
    Sort s     -> killRange1 Sort s

instance KillRange Type where
  killRange (El s v) = killRange2 El s v

instance KillRange Sort where
  killRange = id

instance KillRange Telescope where
  killRange EmptyTel = EmptyTel
  killRange (ExtendTel a tel) = killRange2 ExtendTel a tel

instance KillRange a => KillRange (Blocked a) where
  killRange = fmap killRange

instance KillRange a => KillRange (Abs a) where
  killRange = fmap killRange

-- | Type of argument lists.
--
type Args = [Arg Term]

-- | Sequence of types. An argument of the first type is bound in later types
--   and so on.
data Telescope = EmptyTel
	       | ExtendTel (Arg Type) (Abs Telescope)
  deriving (Typeable, Data, Show, Eq)

instance Sized Telescope where
  size  EmptyTel	 = 0
  size (ExtendTel _ tel) = 1 + size tel

-- | The body has (at least) one free variable.
data Abs a = Abs { absName :: String
		 , absBody :: a
		 }
  deriving (Typeable, Data, Eq)

instance Show a => Show (Abs a) where
  showsPrec p (Abs x a) = showParen (p > 0) $
    showString "Abs " . shows x . showString " " . showsPrec 10 a

instance Functor Abs where
  fmap f (Abs x t) = Abs x $ f t

instance Foldable Abs where
  foldr f z (Abs _ t) = f t z

instance Traversable Abs where
  traverse f (Abs x t) = Abs x <$> f t

instance Sized a => Sized (Abs a) where
  size = size . absBody

telFromList :: [Arg (String, Type)] -> Telescope
telFromList = foldr (\(Arg h (x, a)) -> ExtendTel (Arg h a) . Abs x) EmptyTel

telToList :: Telescope -> [Arg (String, Type)]
telToList EmptyTel = []
telToList (ExtendTel arg (Abs x tel)) = fmap ((,) x) arg : telToList tel

--
-- Definitions
--

-- | A clause is a list of patterns and the clause body should @Bind@ or
-- @NoBind@ in the order the variables occur in the patterns. The @NoBind@
-- constructor is an optimisation to avoid substituting for variables that
-- aren't used.
--
--  The telescope contains the types of the pattern variables and the
--  permutation is how to get from the order the variables occur in the
--  patterns to the order they occur in the telescope.  For the purpose of the
--  permutation dot patterns counts as variables.
--  TODO: change this!
data Clause = Clause
    { clauseRange     :: Range
    , clauseTel       :: Telescope
    , clausePerm      :: Permutation
    , clausePats      :: [Arg Pattern]
    , clauseBody      :: ClauseBody
    }
  deriving (Typeable, Data, Show)
data ClauseBody = Body Term
		| Bind (Abs ClauseBody)
		| NoBind ClauseBody
		| NoBody    -- for absurd clauses
  deriving (Typeable, Data, Show)

instance HasRange Clause where
  getRange = clauseRange

-- | Patterns are variables, constructors, or wildcards.
--   @QName@ is used in @ConP@ rather than @Name@ since
--     a constructor might come from a particular namespace.
--     This also meshes well with the fact that values (i.e.
--     the arguments we are matching with) use @QName@.
--
data Pattern = VarP String  -- name suggestion
             | DotP Term
	     | ConP QName [Arg Pattern]
	     | LitP Literal
  deriving (Typeable, Data, Show)

newtype MetaId = MetaId Nat
    deriving (Eq, Ord, Num, Real, Enum, Integral, Typeable, Data)

instance Show MetaId where
    show (MetaId n) = "_" ++ show n

-- | Doesn't do any reduction.
arity :: Type -> Nat
arity t =
    case unEl t of
	Pi  _ (Abs _ b) -> 1 + arity b
	Fun _	     b	-> 1 + arity b
	_		-> 0

-- | Suggest a name for the first argument of a function of the given type.
argName :: Type -> String
argName = argN . unEl
    where
	argN (Pi _ b)  = "." ++ absName b
	argN (Fun _ _) = ".x"
	argN _	  = __IMPOSSIBLE__


---------------------------------------------------------------------------
-- * Views
---------------------------------------------------------------------------

data FunView
	= FunV (Arg Type) Term	-- ^ second arg is the entire type ('Pi' or 'Fun').
	| NoFunV Term

funView :: Term -> FunView
funView t@(Pi  arg _) = FunV arg t
funView t@(Fun arg _) = FunV arg t
funView t	      = NoFunV t

---------------------------------------------------------------------------
-- * Smart constructors
---------------------------------------------------------------------------

blockingMeta :: Blocked t -> Maybe MetaId
blockingMeta (Blocked m _) = Just m
blockingMeta (NotBlocked _) = Nothing

blocked :: MetaId -> a -> Blocked a
blocked x = Blocked x

notBlocked :: a -> Blocked a
notBlocked = NotBlocked

ignoreBlocking :: Blocked a -> a
ignoreBlocking (Blocked _ x) = x
ignoreBlocking (NotBlocked x) = x

set0   = set 0
set n  = sort $ mkType n
prop   = sort Prop
sort s = El (sSuc s) $ Sort s

mkType n = Type $ Lit $ LitInt noRange n

teleLam :: Telescope -> Term -> Term
teleLam  EmptyTel	  t = t
teleLam (ExtendTel u tel) t = Lam (argHiding u) $ flip teleLam t <$> tel

getSort :: Type -> Sort
getSort (El s _) = s

unEl :: Type -> Term
unEl (El _ t) = t

-- | Get the next higher sort.
sSuc :: Sort -> Sort
sSuc Prop                      = mkType 1
sSuc (Type (Lit (LitInt _ n))) = mkType (n + 1)
sSuc Inf                       = Inf
sSuc s                         = Suc s

sLub :: Sort -> Sort -> Sort
sLub (Type (Lit (LitInt _ 0))) Prop                      = Prop   -- (x:A) -> B prop if A type0, B prop [x:A]
sLub (Type (Lit (LitInt _ n))) Prop                      = mkType n
sLub Prop (Type (Lit (LitInt _ n)))                      = mkType n
sLub (Type (Lit (LitInt _ n))) (Type (Lit (LitInt _ m))) = mkType $ max n m
sLub (Suc a) (Suc b) = Suc (sLub a b)
sLub (Type (Lit (LitInt _ n))) (Suc a)
  | n > 0     = sSuc (mkType (n - 1) `sLub` a)
  | otherwise = Suc a
sLub (Suc a) (Type (Lit (LitInt _ n)))
  | n > 0     = sSuc (a `sLub` mkType (n - 1))
  | otherwise = Suc a
sLub Inf _ = Inf
sLub _ Inf = Inf
sLub s1 s2
    | s1 == s2	= s1
    | otherwise	= Lub s1 s2

