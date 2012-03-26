{-# LANGUAGE CPP #-}

module Agda.TypeChecking.Rules.Record where

import Control.Applicative
import Control.Monad.Trans
import Control.Monad.Reader

import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Position
import qualified Agda.Syntax.Info as Info

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin ( primIrrAxiom )
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Polarity
import Agda.TypeChecking.Irrelevance
import Agda.TypeChecking.CompiledClause.Compile

import Agda.TypeChecking.Rules.Data ( bindParameters, fitsIn )
import Agda.TypeChecking.Rules.Term ( isType_ )
import {-# SOURCE #-} Agda.TypeChecking.Rules.Decl (checkDecl)

import Agda.Utils.Size
import Agda.Utils.Permutation
import Agda.Utils.Monad

import Agda.Interaction.Options


#include "../../undefined.h"
import Agda.Utils.Impossible

---------------------------------------------------------------------------
-- * Records
---------------------------------------------------------------------------

-- | @checkRecDef i name con ps contel fields@
--
--     [@name@]    Record type identifier.
--
--     [@con@]     Maybe constructor name and info.
--
--     [@ps@]      Record parameters.
--
--     [@contel@]  Approximate type of constructor (@fields@ -> Set).
--
--     [@fields@]  List of field signatures.
--
checkRecDef :: Info.DefInfo -> QName -> Maybe A.QName -> --Maybe A.Constructor ->
               [A.LamBinding] -> A.Expr -> [A.Constructor] -> TCM ()
checkRecDef i name con ps contel fields =
  traceCall (CheckRecDef (getRange i) (qnameName name) ps fields) $ do
    reportSDoc "tc.rec" 10 $ vcat
      [ text "checking record def" <+> prettyTCM name
      , nest 2 $ text "ps ="     <+> prettyList (map prettyA ps)
      , nest 2 $ text "contel =" <+> prettyA contel
      , nest 2 $ text "fields =" <+> prettyA (map Constr fields)
      ]
    -- get type of record
    t <- instantiateFull =<< typeOfConst name
    bindParameters ps t $ \tel t0 -> do

      -- Generate type of constructor from field telescope @contel@,
      -- which is the approximate constructor type (target missing).

      -- Check and evaluate field types.
      reportSDoc "tc.rec" 15 $ text "checking fields"
      -- WRONG: contype <- workOnTypes $ killRange <$> (instantiateFull =<< isType_ contel)
      contype <- killRange <$> (instantiateFull =<< isType_ contel)

      -- compute the field telescope
      let TelV ftel _ = telView' contype

          -- A record is irrelevant if all of its fields are.
          -- In this case, the associated module parameter will be irrelevant.
          -- See issue 392.
          recordRelevance = minimum $ Irrelevant : (map argRelevance $ telToList ftel)

      -- Compute correct type of constructor

      -- t = tel -> t0 where t0 must be a sort s
      t0' <- normalise t0
      s <- case unEl t0' of
	Sort s	-> return s
	_	-> typeError $ ShouldBeASort t0
      gamma <- getContextTelescope
      let m               = qnameToMName name
          -- make record parameters hidden and non-stricts irrelevant
	  htel		  = map hideAndRelParams $ telToList tel
          -- record type (name applied to parameters)
	  rect		  = El s $ Def name $ teleArgs gamma
{-
	  rect		  = El s $ Def name $ reverse
			    [ Arg h r (var i)
			    | (i, Arg h r _) <- zip [0..] $ reverse $ telToList gamma
			    ]
-}
	  telh' h	  = telFromList $ htel ++ [Arg h recordRelevance ("r", rect)]
	  tel'		  = telh' NotHidden
	  telIFS	  = telh' Instance
          extWithRH h ret = underAbstraction (Arg h recordRelevance rect) (Abs "" ()) $ \_ -> ret
          extWithR        = extWithRH NotHidden
          ext     (Arg h r (x, t)) = addCtx x (Arg h r t)
{- UNUSED
          extHide (Arg h r (x, t)) = addCtx x (Arg Hidden r t)
-}

      -- Put in @rect@ as correct target of constructor type.
      -- Andreas, 2011-05-10 use telePi_ instead of telePi to preserve
      -- even names of non-dependent fields in constructor type (Issue 322).
      let contype = telePi_ ftel (raise (size ftel) rect)

      -- Obtain name of constructor (if present).
      (hasNamedCon, conName, conInfo) <- case con of
        Just c  -> return (True, c, i)
        Nothing -> do
          m <- killRange <$> currentModule
          c <- qualify m <$> freshName_ "recCon-NOT-PRINTED"
          return (False, c, i)

      -- Add record type to signature.
      reportSDoc "tc.rec" 15 $ text "adding record type to signature"

      let getName :: A.Declaration -> [Arg QName]
          getName (A.Field _ x arg)    = [fmap (const x) arg]
	  getName (A.ScopedDecl _ [f]) = getName f
	  getName _		       = []

      addConstant name $ Defn Relevant name t0 (defaultDisplayForm name) 0 noCompiledRep
		       $ Record { recPars           = 0
                                , recClause         = Nothing
                                , recCon            = conName
                                , recNamedCon       = hasNamedCon
                                , recConType        = contype
				, recFields         = concatMap getName fields
                                , recTel            = ftel
				, recAbstr          = Info.defAbstract i
                                , recEtaEquality    = True
                                , recPolarity       = []
                                , recArgOccurrences = []
                                }

      -- Add record constructor to signature
      -- Andreas, 2011-05-19 moved this here, it was below the record module
      --   creation
      addConstant conName $
        Defn Relevant conName contype (defaultDisplayForm conName) 0 noCompiledRep $
             Constructor { conPars   = 0
                         , conSrcCon = conName
                         , conData   = name
                         , conAbstr  = Info.defAbstract conInfo
                         , conInd    = Inductive
                         }

      -- Check that the fields fit inside the sort
      let dummy = var 0  -- We're only interested in the sort here
      telePi ftel (El s dummy) `fitsIn` s

      {- Andreas, 2011-04-27 WRONG because field types are checked again
         and then non-stricts should not yet be irrelevant

      -- make record parameters hidden and non-stricts irrelevant
      -- ctx <- (reverse . map hideAndRelParams . take (size tel)) <$> getContext
      -}

      -- make record parameters hidden
      ctx <- (reverse . map hide . take (size tel)) <$> getContext

      escapeContext (size tel) $ flip (foldr ext) ctx $ extWithR $ do
	reportSDoc "tc.rec.def" 10 $ sep
	  [ text "record section:"
	  , nest 2 $ sep
            [ prettyTCM m <+> (inContext [] . prettyTCM =<< getContextTelescope)
            , fsep $ punctuate comma $ map (text . show . getName) fields
            ]
	  ]
        reportSDoc "tc.rec.def" 15 $ nest 2 $ vcat
          [ text "field tel =" <+> escapeContext 1 (prettyTCM ftel)
          ]
	addSection m (size tel')

        -- Check the types of the fields
        -- ftel <- checkRecordFields m name tel s [] (size fields) fields
        withCurrentModule m $
          checkRecordProjections m name conName tel' (raise 1 ftel) fields

      -- Andreas, 2011-05-19 here was the code "Add record constr..."

        -- Andreas 2012-02-13: postpone polarity computation until after positivity check
        -- computePolarity name

      return ()

{-| @checkRecordProjections m r q tel ftel fs@.

    [@m@    ]  name of the generated module

    [@r@    ]  name of the record type

    [@q@    ]  name of the record constructor

    [@tel@  ]  parameters

    [@ftel@ ]  telescope of fields

    [@fs@   ]  the fields to be checked
-}
checkRecordProjections ::
  ModuleName -> QName -> QName -> Telescope -> Telescope ->
  [A.Declaration] -> TCM ()
checkRecordProjections m r q tel ftel fs = checkProjs EmptyTel ftel fs
  where

    checkProjs :: Telescope -> Telescope -> [A.Declaration] -> TCM ()

    checkProjs _ _ [] = return ()

    checkProjs ftel1 ftel2 (A.ScopedDecl scope fs' : fs) =
      setScope scope >> checkProjs ftel1 ftel2 (fs' ++ fs)

    checkProjs ftel1 (ExtendTel _ ftel2) (A.Field info x (Arg h rel t) : fs) = do
      -- check the type (in the context of the telescope)
      -- the previous fields will be free in
      reportSDoc "tc.rec.proj" 5 $ sep
	[ text "checking projection"
	, nest 2 $ vcat
	  [ text "top   =" <+> (inContext [] . prettyTCM =<< getContextTelescope)
	  , text "ftel1 =" <+> prettyTCM ftel1
	  , text "ftel2 =" <+> addCtxTel ftel1 (underAbstraction_ ftel2 prettyTCM)
	  , text "t     =" <+> prettyTCM t
	  ]
	]
      -- Andreas, 2011-04-27 work on rhs of ':'
      -- WRONG: t <- workOnTypes $ isType_ t
      t <- isType_ t

      -- Andreas, 2010-09-09 The following comments are misleading, TODO: update
      -- in fact, tel includes the variable of record type as last one
      -- e.g. for cartesion product it is
      --
      --   tel = {A' : Set} {B' : Set} (r : Prod A' B')

      -- create the projection functions (instantiate the type with the values
      -- of the previous fields)

      {- what are the contexts?

	  Γ, tel            ⊢ t
	  Γ, tel, r         ⊢ vs
	  Γ, tel, r, ftel₁  ⊢ raiseFrom (size ftel₁) 1 t
      -}

      -- The type of the projection function should be
      --  {tel} -> (r : R Δ) -> t
      -- where Δ = Γ, tel is the current context
      let finalt   = telePi tel t
	  projname = qualify m $ qnameName x
          -- the recursive call
          recurse  = checkProjs (abstract ftel1 $ ExtendTel (Arg h rel t)
                                 $ Abs (show $ qnameName projname) EmptyTel)
                                (absBody ftel2) fs

      -- Andreas, 2012-02-20 do not add irrelevant projections if
      -- disabled by --no-irrelevant-projections
      ifM (return (rel == Irrelevant) `and2M` do not . optIrrelevantProjections <$> pragmaOptions) recurse $ do

      reportSDoc "tc.rec.proj" 10 $ sep
	[ text "adding projection"
	, nest 2 $ prettyTCM projname <+> text ":" <+> inContext [] (prettyTCM finalt)
	]

      -- The body should be
      --  P.xi {tel} (r _ .. x .. _) = x
      -- Ulf, 2011-08-22: actually we're dropping the parameters from the
      -- projection functions so the body is now
      --  P.xi (r _ .. x .. _) = x
      -- Andreas, 2012-01-12: irrelevant projections get translated to
      --  P.xi (r _ .. x .. _) = irrAxiom {level of t} {t} x
      -- PROBLEM: because of dropped parameters, cannot refer to t

      -- compute body modification for irrelevant projections
      bodyMod <- do
        case rel of
          Relevant   -> return $ const $ id -- no modification

          Irrelevant -> do
            irrAxiom <- primIrrAxiom
            let sortToLevel (Type l) = l
                sortToLevel _        = Max [ClosedLevel 0] -- something random here, we don't care a lot
                levelOfT = Level $ sortToLevel $ getSort t
            return $ \ n x -> let -- mkArg t = Arg Hidden Relevant $ raise n t
                                  -- ERR: Variables of t not in Scope!
                                  mkArg t = Arg Hidden Relevant $ Sort Prop
                              in  apply irrAxiom [mkArg levelOfT, mkArg (unEl t), Arg NotHidden Irrelevant x]

          _          -> __IMPOSSIBLE__

      let -- Andreas, 2010-09-09: comment for existing code
          -- split the telescope into parameters (ptel) and the type or the record
          -- (rt) which should be  R ptel
          (ptel,[rt]) = splitAt (size tel - 1) $ telToList tel
	  conp	 = defaultArg
		 $ ConP q (Just (fmap snd rt))
                   $ zipWith3 Arg
                              (map argHiding (telToList ftel))
                              (map argRelevance (telToList ftel))
			      [ VarP "x" | _ <- [1..size ftel] ]
	  nobind 0 = id
	  nobind n = Bind . Abs "_" . nobind (n - 1)
	  body	 = nobind (size ftel1)
		 $ Bind . Abs "x"
		 $ nobind (size ftel2)
		 $ Body $ bodyMod (size ftel) $ Var (size ftel2) []
          cltel  = ftel
	  clause = Clause { clauseRange = getRange info
                          , clauseTel   = killRange cltel
                          , clausePerm  = idP $ size ftel
                          , clausePats  = [conp]
                          , clauseBody  = body
                          }

      reportSDoc "tc.rec.proj" 20 $ sep
	[ text "adding projection"
	, nest 2 $ prettyTCM projname <+> text (show clause)
	]
      reportSDoc "tc.rec.proj" 10 $ sep
	[ text "adding projection"
	, nest 2 $ prettyTCM projname <+> text (show (clausePats clause)) <+> text "=" <+>
                     inContext [] (addCtxTel ftel (prettyTCM (clauseBody clause)))
	]

            -- Record patterns should /not/ be translated when the
            -- projection functions are defined. Record pattern
            -- translation is defined in terms of projection
            -- functions.
      cc <- compileClauses False [clause]

      reportSDoc "tc.cc" 10 $ do
        sep [ text "compiled clauses of " <+> prettyTCM projname
            , nest 2 $ text (show cc)
            ]

      escapeContext (size tel) $ do
	addConstant projname $ Defn rel projname (killRange finalt) (defaultDisplayForm projname) 0 noCompiledRep
          $ Function { funClauses        = [clause]
                     , funCompiled       = cc
                     , funDelayed        = NotDelayed
                     , funInv            = NotInjective
                     , funAbstr          = ConcreteDef
                     , funPolarity       = []
                     , funArgOccurrences = [Negative]
                     , funProjection     = Just (r, size ptel + 1)
                       -- name of the record type and
                       -- index of the record argument (in the type), start counting with 1
                     , funStatic         = False
                     }
        computePolarity projname

      recurse
{-
      checkProjs (abstract ftel1 $ ExtendTel (Arg h rel t)
                                 $ Abs (show $ qnameName projname) EmptyTel
                 ) (absBody ftel2) fs
-}

    checkProjs ftel1 ftel2 (d : fs) = do
      checkDecl d
      checkProjs ftel1 ftel2 fs
