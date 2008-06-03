{-# OPTIONS -cpp #-}

module Agda.TypeChecking.Rules.LHS.Split where

import Control.Applicative
import Control.Monad.Error
import Data.Monoid
import Data.List

import Agda.Syntax.Common
import Agda.Syntax.Literal
import Agda.Syntax.Position
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Pattern
import qualified Agda.Syntax.Abstract as A
import qualified Agda.Syntax.Info as A

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Constraints
import Agda.TypeChecking.Conversion
import Agda.TypeChecking.Rules.LHS.Problem
import Agda.TypeChecking.Rules.Term
import Agda.TypeChecking.Monad.Builtin

import Agda.Utils.Permutation
import Agda.Utils.Tuple

#include "../../../undefined.h"
import Agda.Utils.Impossible

instance (Monad m, Error err) => Applicative (ErrorT err m) where
  pure	= return
  (<*>) = ap

instance (Error err, MonadTCM tcm) => MonadTCM (ErrorT err tcm) where
  liftTCM = lift . liftTCM

-- | TODO: move to Agda.Syntax.Abstract.View
asView :: A.Pattern -> ([Name], A.Pattern)
asView (A.AsP _ x p) = (x :) -*- id $ asView p
asView p	     = ([], p)

-- | Split a problem at the first constructor of datatype type. Implicit
--   patterns should have been inserted.
splitProblem :: Problem -> TCM (Either SplitError SplitProblem)
splitProblem (Problem ps (perm, qs) tel) = do
    reportS "tc.lhs.split" 20 $ "initiating splitting\n"
    runErrorT $
      splitP ps (permute perm $ zip [0..] $ allHoles qs) tel
  where
    splitP :: [NamedArg A.Pattern] -> [(Int, OneHolePatterns)] -> Telescope -> ErrorT SplitError TCM SplitProblem
    splitP _	    []		 (ExtendTel _ _)	 = __IMPOSSIBLE__
    splitP _	    (_:_)	  EmptyTel		 = __IMPOSSIBLE__
    splitP []	     _		  _			 = throwError $ NothingToSplit
    splitP ps	    []		  EmptyTel		 = __IMPOSSIBLE__
    splitP (p : ps) ((i, q) : qs) tel0@(ExtendTel a tel) =
      case asView $ namedThing $ unArg p of
	(xs, A.LitP (LitInt r n)) | n < 0     -> __IMPOSSIBLE__
                                  | n > 20    -> typeError $ GenericError $
                                                "Matching on natural number literals is done by expanding "
                                                ++ "the literal to the corresponding constructor pattern, so "
                                                ++ "you probably don't want to do it this way."
                                  | otherwise -> do
          Con z _ <- primZero
          Con s  _ <- primSuc
          let zero  = A.ConP info [setRange r z] []
              suc p = A.ConP info [setRange r s] [Arg NotHidden $ unnamed p]
              info  = A.PatRange r
              p'    = fmap (fmap $ const $ foldr ($) zero $ replicate (fromIntegral n) suc) p
          splitP (p' : ps) ((i, q) : qs) tel0
	(xs, A.LitP lit)  -> do
	  b <- lift $ litType lit
	  ok <- lift $ do
	      noConstraints (equalType (unArg a) b)
	      return True
	    `catchError` \_ -> return False
	  if ok
	    then return $
	      Split mempty
		    xs
		    (fmap (LitFocus lit q i) a)
		    (fmap (Problem ps ()) tel)
	    else keepGoing
	(xs, p@(A.ConP _ cs args)) -> do
	  a' <- reduce $ unArg a
	  case unEl a' of
	    Def d vs	-> do
	      def <- theDef <$> getConstInfo d
	      case def of
		Datatype{dataPars = np} ->
		  traceCall (CheckPattern p EmptyTel (unArg a)) $ do  -- TODO: wrong telescope
                  -- Check that we construct something in the right datatype
                  c <- do
                      cs' <- mapM canonicalName cs
                      d'  <- canonicalName d
                      Datatype{dataCons = cs0} <- theDef <$> getConstInfo d'
                      case [ c | (c, c') <- zip cs cs', elem c' cs0 ] of
                        [c] -> return c
                        []  -> typeError $ ConstructorPatternInWrongDatatype (head cs) d
                        _   -> __IMPOSSIBLE__
		  let (pars, ixs) = genericSplitAt np vs
		  reportSDoc "tc.lhs.split" 10 $
		    vcat [ sep [ text "splitting on"
			       , nest 2 $ fsep [ prettyA p, text ":", prettyTCM a ]
			       ]
			 , nest 2 $ text "pars =" <+> fsep (punctuate comma $ map prettyTCM pars)
			 , nest 2 $ text "ixs  =" <+> fsep (punctuate comma $ map prettyTCM ixs)
			 ]
		  return $ Split mempty
				 xs
				 (fmap (const $ Focus c args (getRange p) q i d pars ixs) a)
				 (fmap (Problem ps ()) tel)
		-- TODO: record patterns
		_ -> keepGoing
	    _	-> keepGoing
	p -> keepGoing
      where
	keepGoing = do
	  let p0 = Problem [p] () (ExtendTel a $ fmap (const EmptyTel) tel)
	  Split p1 xs foc p2 <- underAbstraction a tel $ \tel -> splitP ps qs tel
	  return $ Split (mappend p0 p1) xs foc p2

