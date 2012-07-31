{-# LANGUAGE CPP, PatternGuards #-}

module Agda.TypeChecking.Rules.LHS.Implicit where

import Data.Maybe
import Control.Applicative

import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Info
import Agda.Syntax.Internal
import qualified Agda.Syntax.Abstract as A

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Implicit
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Records
import Agda.TypeChecking.Reduce

import Agda.TypeChecking.Rules.LHS.Problem

import Agda.Utils.Monad

#include "../../../undefined.h"
import Agda.Utils.Impossible

-- | Insert implicit patterns in a problem.
insertImplicitProblem :: Problem -> TCM Problem
insertImplicitProblem (Problem ps qs tel pr) = do
  reportSDoc "tc.lhs.imp" 15 $
    sep [ text "insertImplicits"
	, nest 2 $ brackets $ fsep $ punctuate comma $ map prettyA ps
	, nest 2 $ prettyTCM tel
	]
  ps' <- insertImplicitPatterns ExpandLast ps tel
  return $ Problem ps' qs tel pr

-- | Insert implicit patterns in a list of patterns.
insertImplicitPatterns :: ExpandHidden -> [NamedArg A.Pattern] -> Telescope -> TCM [NamedArg A.Pattern]
insertImplicitPatterns exh            ps EmptyTel = return ps
insertImplicitPatterns DontExpandLast [] tel      = return []
insertImplicitPatterns exh ps tel@(ExtendTel arg tel') = case ps of
  [] -> do
    i <- insImp dummy tel
    case i of
      Just []   -> __IMPOSSIBLE__
      Just hs	-> return $ implicitPs hs
      Nothing	-> return []
  p : ps -> do
    i <- insImp p tel
    case i of
      Just []	-> __IMPOSSIBLE__
      Just hs	-> insertImplicitPatterns exh (implicitPs hs ++ p : ps) tel
      Nothing
        | A.ImplicitP{} <- namedThing $ unArg p,
          argHiding p /= Instance -> do
          -- Eta expand implicit patterns of record type (issue 473),
          -- but not instance arguments since then they won't be found
          -- by the instance search
          a <- reduce (unDom arg)
          case unEl a of
            Def d _ ->
              -- Andreas, 2012-06-10: only expand guarded records,
              -- otherwise we might run into an infinite loop
              ifM (isEtaRecord d) (do
                c  <- getRecordConstructor d
                fs <- getRecordFieldNames d
                let qs = map (implicitP <$) fs
                continue ((A.ConP (PatRange noRange) (A.AmbQ [c]) qs <$) <$> p)
              ) (continue p)
            _ -> continue p
        | otherwise -> continue p
        where
          continue p = (p :) <$> insertImplicitPatterns exh ps (absBody tel')
  where
    dummy = defaultArg $ unnamed ()

    insImp x tel = case insertImplicit x $ map (argFromDom . fmap fst) $ telToList tel of
      BadImplicits   -> typeError $ WrongHidingInLHS (telePi tel $ sort Prop)
      NoSuchName x   -> typeError $ WrongHidingInLHS (telePi tel $ sort Prop)
      ImpInsert n    -> return $ Just n
      NoInsertNeeded -> return Nothing

    implicitP = unnamed $ A.ImplicitP $ PatRange $ noRange

    implicitPs [] = []
    implicitPs (h : hs) = (Arg h Relevant implicitP) : implicitPs hs
