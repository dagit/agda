{-# LANGUAGE CPP, PatternGuards #-}
module Agda.TypeChecking.CompiledClause.Match where

import Control.Applicative
import qualified Data.Map as Map
import Data.Traversable
import Data.List

import Agda.Syntax.Internal
import Agda.Syntax.Common
import Agda.TypeChecking.CompiledClause
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Primitive

import Agda.Utils.List

import Agda.Utils.Impossible
#include "../../undefined.h"

matchCompiled :: CompiledClauses -> MaybeReducedArgs -> TCM (Reduced (Blocked Args) Term)
matchCompiled c args = match c args id []

type Stack = [(CompiledClauses, MaybeReducedArgs, Args -> Args)]

-- TODO: literal/constructor pattern conflict (for Nat)

match :: CompiledClauses -> MaybeReducedArgs -> (Args -> Args) -> Stack -> TCM (Reduced (Blocked Args) Term)
match Fail args patch stack = return $ NoReduction $ NotBlocked (patch $ map ignoreReduced args)
match (Done hs t) args _ _
  | m < n     = return $ YesReduction $ substs (reverse $ toTm args)
                                      $ foldr lam t (drop m hs)
  | otherwise = return $ YesReduction $ substs (reverse $ toTm args0) t `apply` map ignoreReduced args1
  where
    n              = length hs
    m              = length args
    toTm           = map (unArg . ignoreReduced)
    (args0, args1) = splitAt n args
    lam h t        = Lam h (Abs "x" t)
match (Case n bs) args patch stack =
  case genericSplitAt n args of
    (_, []) -> return $ NoReduction $ NotBlocked $ patch $ map ignoreReduced args
    (args0, MaybeRed red (Arg h r v0) : args1) -> do
      w  <- case red of
              Reduced b  -> return $ fmap (const v0) b
              NotReduced ->
                unfoldCorecursion =<< instantiate v0
      cv <- constructorForm $ ignoreBlocking w
      let v      = ignoreBlocking w
          args'  = args0 ++ [MaybeRed red $ Arg h r v] ++ args1
          stack' = maybe [] (\c -> [(c, args', patch)]) (catchAllBranch bs)
                   ++ stack
          patchLit args = patch (args0 ++ [Arg h r v] ++ args1)
            where (args0, args1) = splitAt n args
          patchCon c m args = patch (args0 ++ [Arg h r $ Con c vs] ++ args1)
            where (args0, args1') = splitAt n args
                  (vs, args1)     = splitAt m args1'
      case w of
        Blocked x _            -> return $ NoReduction $ Blocked x (patch $ map ignoreReduced args')
        NotBlocked (MetaV x _) -> return $ NoReduction $ Blocked x (patch $ map ignoreReduced args')
        NotBlocked (Lit l) -> case Map.lookup l (litBranches bs) of
          Nothing -> match' stack''
          Just cc -> match cc (args0 ++ args1) patchLit stack''
          where
            stack'' = (++ stack') $ case cv of
              Con c vs -> case Map.lookup c (conBranches bs) of
                Nothing -> []
                Just cc -> [(cc, args0 ++ map (MaybeRed red) vs ++ args1, patchCon c (length vs))]
              _        -> []
        NotBlocked (Con c vs) -> case Map.lookup c (conBranches bs) of
          Nothing -> match' stack'
          Just cc -> match cc (args0 ++ map (MaybeRed red) vs ++ args1)
                              (patchCon c (length vs)) stack'
        NotBlocked _ -> return $ NoReduction $ NotBlocked (patch $ map ignoreReduced args')

match' :: Stack -> TCM (Reduced (Blocked Args) Term)
match' ((c, args, patch):stack) = match c args patch stack
match' [] = typeError $ GenericError "Incomplete pattern matching"

unfoldCorecursion v = case v of
  Def f args -> unfoldDefinition True unfoldCorecursion (Def f []) f args
  _          -> reduceB v
