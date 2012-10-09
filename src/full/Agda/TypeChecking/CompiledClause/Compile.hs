{-# LANGUAGE CPP #-}
module Agda.TypeChecking.CompiledClause.Compile where

import Data.Monoid
import qualified Data.Map as Map
import Data.List (genericReplicate, nubBy)
import Data.Function

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.TypeChecking.CompiledClause
import Agda.TypeChecking.Coverage
import Agda.TypeChecking.Coverage.SplitTree
import Agda.TypeChecking.Monad
import Agda.TypeChecking.RecordPatterns
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Pretty
import Agda.Utils.List

import Agda.Utils.Impossible
#include "../../undefined.h"

-- | Process function clauses into case tree.
--   This involves:
--   1. Coverage checking, generating a split tree.
--   2. Translation of lhs record patterns into rhs uses of projection.
--      Update the split tree.
--   3. Generating a case tree from the split tree.
--   Phases 1. and 2. are skipped if @Nothing@.
compileClauses ::
  Maybe (QName, Type) -- ^ Translate record patterns and coverage check with given type?
  -> [Clause] -> TCM CompiledClauses
compileClauses mt cs = case mt of
  Nothing -> return $ compile Nothing [(clausePats c, clauseBody c) | c <- cs]
  Just (q, t)  -> do
    splitTree <- translateSplitTree =<< coverageCheck q t cs
    reportSDoc "tc.cc.splittree" 10 $ vcat
      [ text "translated split tree for" <+> prettyTCM q
      , text $ show splitTree
      ]
    cs        <- mapM translateRecordPatterns cs
    return $ compile (Just splitTree) [(clausePats c, clauseBody c) | c <- cs]

type Cl  = ([Arg Pattern], ClauseBody)
type Cls = [Cl]

compile :: Maybe SplitTree -> Cls -> CompiledClauses
compile mt cs = case nextSplit cs of
  Just n  -> Case n $ fmap (compile mt) $ splitOn n cs
  Nothing -> case map getBody cs of
    -- It's possible to get more than one clause here due to
    -- catch-all expansion.
    Just t : _  -> Done (map (fmap name) $ fst $ head cs) (shared t)
    Nothing : _ -> Fail
    []          -> __IMPOSSIBLE__
  where
    name (VarP x) = x
    name (DotP _) = "_"
    name ConP{} = __IMPOSSIBLE__
    name LitP{} = __IMPOSSIBLE__
    getBody (_, b) = body b
    body (Bind b)   = body (absBody b)
    body (Body t)   = Just t
    body NoBody     = Nothing

-- | Get the index of the next argument we need to split on.
--   This the number of the first pattern that does a match in the first clause.
nextSplit :: Cls -> Maybe Int
nextSplit [] = __IMPOSSIBLE__
nextSplit ((ps, _):_) = mhead [ n | (a, n) <- zip ps [0..], isPat (unArg a) ]
  where
    isPat VarP{} = False
    isPat DotP{} = False
    isPat ConP{} = True
    isPat LitP{} = True

splitOn :: Int -> Cls -> Case Cls
splitOn n cs = mconcat $ map (fmap (:[]) . splitC n) $ expandCatchAlls n cs

splitC :: Int -> Cl -> Case Cl
splitC n (ps, b) = case unArg p of
  ConP c _ qs -> conCase c (ps0 ++ qs ++ ps1, b)
  LitP l      -> litCase l (ps0 ++ ps1, b)
  _           -> catchAll (ps, b)
  where
    (ps0, p, ps1) = extractNthElement' n ps

-- Expand catch-alls that appear before actual matches.
expandCatchAlls :: Int -> Cls -> Cls
expandCatchAlls n cs = case cs of
  _            | all (isCatchAll . nth . fst) cs -> cs
  (ps, b) : cs | not (isCatchAll (nth ps)) -> (ps, b) : expandCatchAlls n cs
               | otherwise -> map (expand ps b) expansions ++ (ps, b) : expandCatchAlls n cs
  _ -> __IMPOSSIBLE__
  where
    isCatchAll (Arg _ _ ConP{}) = False
    isCatchAll (Arg _ _ LitP{}) = False
    isCatchAll _      = True
    nth qs = p
      where (_, p, _) = extractNthElement' n qs

    classify (LitP l)     = Left l
    classify (ConP c _ _) = Right c
    classify _            = __IMPOSSIBLE__

    -- All non-catch-all patterns following this one (at position n).
    -- These are the cases the wildcard needs to be expanded into.
    expansions = nubBy ((==) `on` classify)
               . map unArg
               . filter (not . isCatchAll)
               . map (nth . fst) $ cs

    expand ps b q =
      case q of
        ConP c _ qs' -> (ps0 ++ [defaultArg $ ConP c Nothing (genericReplicate m $ defaultArg $ VarP "_")] ++ ps1,
                         substBody n' m (Con c (map var [m - 1, m - 2..0])) b)
          where m = length qs'
        LitP l -> (ps0 ++ [defaultArg $ LitP l] ++ ps1, substBody n' 0 (Lit l) b)
        _ -> __IMPOSSIBLE__
      where
        (ps0, _, ps1) = extractNthElement' n ps

        n' = countVars ps0
        countVars = sum . map (count . unArg)
        count VarP{}        = 1
        count (ConP _ _ ps) = countVars ps
        count DotP{}        = 1   -- dot patterns are treated as variables in the clauses
        count _             = 0

        var x = defaultArg $ Var x []

substBody :: Int -> Int -> Term -> ClauseBody -> ClauseBody
substBody _ _ _ NoBody = NoBody
substBody 0 m v b = case b of
  Bind   b -> foldr (.) id (replicate m (Bind . Abs "_")) $ subst v (absBody $ raise m b)
  _        -> __IMPOSSIBLE__
substBody n m v b = case b of
  Bind b   -> Bind $ fmap (substBody (n - 1) m v) b
  _        -> __IMPOSSIBLE__
