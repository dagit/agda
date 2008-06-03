{-# OPTIONS -cpp #-}

module Agda.TypeChecking.Coverage.Match where

import Control.Applicative
import Control.Monad.State
import Data.Monoid
import Data.Traversable (traverse)
import Data.Function

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Pattern
import Agda.Syntax.Literal

import Agda.Utils.Permutation
import Agda.Utils.Size

#include "../../undefined.h"
import Agda.Utils.Impossible

-- | We use a special representation of the patterns we're trying to match
--   against a clause. In particular we want to keep track of which variables
--   are blocking a match.
data MPat = VarMP Nat | ConMP QName [Arg MPat] | LitMP Literal | WildMP

buildMPatterns :: Permutation -> [Arg Pattern] -> [Arg MPat]
buildMPatterns perm ps = evalState (mapM (traverse build) ps) xs
  where
    xs   = permute (invertP perm) $ reverse [0 .. fromIntegral (size perm) - 1]
    tick = do x : xs <- get; put xs; return x

    build (VarP _)      = VarMP <$> tick
    build (ConP con ps) = ConMP con <$> mapM (traverse build) ps
    build (DotP t)      = tick *> buildT t
    build (LitP l)      = return $ LitMP l

    buildT (Con c args) = ConMP c <$> mapM (traverse buildT) args
    buildT (Var i [])   = return (VarMP i)
    buildT _            = return WildMP

-- | If matching is inconclusive (@Block@) we want to know which
--   variable is blocking the match. If a dot pattern is blocking a match
--   we're screwed.
data Match = Yes | No | Block (Maybe Nat)

instance Monoid Match where
  mempty                    = Yes
  Yes     `mappend` Yes     = Yes
  Yes     `mappend` No      = No
  Yes     `mappend` Block x = Block x
  No      `mappend` _       = No
  Block x `mappend` _       = Block x

choice :: Match -> Match -> Match
choice Yes _       = Yes
choice (Block x) _ = Block x
choice No m        = m

-- | Match the given patterns against a list of clauses
match :: [Clause] -> [Arg Pattern] -> Permutation -> Match
match cs ps perm = foldr choice No $ map (flip matchClause $ buildMPatterns perm ps) cs

matchClause :: Clause -> [Arg MPat] -> Match
matchClause (Clause _ _ ps _) qs = matchPats ps qs

matchPats :: [Arg Pattern] -> [Arg MPat] -> Match
matchPats ps qs = mconcat $ zipWith matchPat (map unArg ps) (map unArg qs)

matchPat :: Pattern -> MPat -> Match
matchPat (VarP _) _ = Yes
matchPat (DotP _) _ = Yes
matchPat (LitP l) _ = No
matchPat (ConP c ps) q = case q of
  VarMP x -> Block $ Just x
  WildMP  -> Block Nothing
  ConMP c' qs
    | c == c'   -> matchPats ps qs
    | otherwise -> No
  LitMP _ -> __IMPOSSIBLE__
