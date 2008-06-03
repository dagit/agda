{-# OPTIONS -cpp #-}
module Agda.TypeChecking.Constraints where

import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Error
import Control.Applicative
import Data.Map as Map
import Data.List as List

import Agda.Syntax.Internal
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Errors
import Agda.TypeChecking.Reduce

#ifndef __HADDOCK__
import {-# SOURCE #-} Agda.TypeChecking.Rules.Term (checkExpr)
import {-# SOURCE #-} Agda.TypeChecking.Conversion
import {-# SOURCE #-} Agda.TypeChecking.MetaVars
#endif

import Agda.Utils.Fresh

#include "../undefined.h"
import Agda.Utils.Impossible

-- | Catch pattern violation errors and adds a constraint.
--
catchConstraint :: MonadTCM tcm => Constraint -> TCM Constraints -> tcm Constraints
catchConstraint c v = liftTCM $
   catchError v $ \err ->
   case err of
       PatternErr s -> put s >> buildConstraint c
       _	    -> throwError err

-- | Try to solve the constraints to be added.
addNewConstraints :: MonadTCM tcm => Constraints -> tcm ()
addNewConstraints cs = do addConstraints cs; wakeupConstraints

-- | Don't allow the argument to produce any constraints.
noConstraints :: MonadTCM tcm => tcm Constraints -> tcm ()
noConstraints m = do
    cs <- solveConstraints =<< m
    unless (List.null cs) $ typeError $ UnsolvedConstraints cs
    return ()

-- | Guard constraint
guardConstraint :: MonadTCM tcm => tcm Constraints -> Constraint -> tcm Constraints
guardConstraint m c = do
    cs <- solveConstraints =<< m
    case List.partition isSortConstraint cs of   -- sort constraints doesn't block anything
	(scs, []) -> (scs ++) <$> solveConstraint c
	(scs, cs) -> (scs ++) <$> buildConstraint (Guarded c cs)
    where
	isSortConstraint = isSC . clValue
	isSC (SortEq _ _)    = True
	isSC (ValueEq _ _ _) = False
	isSC (TypeEq _ _)    = False
	isSC (Guarded c _)   = isSC c
	isSC (UnBlock _)     = False

-- | We ignore the constraint ids and (as in Agda) retry all constraints every time.
--   We probably generate very few constraints.
wakeupConstraints :: MonadTCM tcm => tcm ()
wakeupConstraints = do
    cs <- takeConstraints
    cs <- solveConstraints cs
    addConstraints cs

solveConstraints :: MonadTCM tcm => Constraints -> tcm Constraints
solveConstraints cs = do
    n  <- length <$> getInstantiatedMetas
    cs <- concat <$> mapM (withConstraint solveConstraint) cs
    n' <- length <$> getInstantiatedMetas
    if (n' > n)
	then solveConstraints cs -- Go again if we made progress
	else return cs

solveConstraint :: MonadTCM tcm => Constraint -> tcm Constraints
solveConstraint (ValueEq a u v) = equalTerm a u v
solveConstraint (TypeEq a b)	= equalType a b
solveConstraint (SortEq s1 s2)	= equalSort s1 s2
solveConstraint (Guarded c cs)	= guardConstraint (return cs) c
solveConstraint (UnBlock m) = do
    inst <- mvInstantiation <$> lookupMeta m
    case inst of
      BlockedConst t -> do
        verbose 5 $ do
            d <- prettyTCM t
            debug $ show m ++ " := " ++ show d
        assignTerm m t
        return []
      PostponedTypeCheckingProblem cl -> enterClosure cl $ \(e, t, unblock) -> do
        b <- liftTCM unblock
        if not b
          then buildConstraint $ UnBlock m
          else do
            tel <- getContextTelescope
            v   <- liftTCM $ checkExpr e t
            assignTerm m $ teleLam tel v
            return []
      _ -> __IMPOSSIBLE__
