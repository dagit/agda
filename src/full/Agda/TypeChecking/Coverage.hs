{-# LANGUAGE CPP, FlexibleContexts, TupleSections #-}

module Agda.TypeChecking.Coverage where

import Control.Monad
import Control.Monad.Error
import Control.Applicative
import Data.List
import qualified Data.Set as Set
import Data.Set (Set)

import Agda.Syntax.Position
import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Pattern

import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Monad.Closure
import Agda.TypeChecking.Monad.Trace
import Agda.TypeChecking.Monad.Signature
import Agda.TypeChecking.Monad.Options
import Agda.TypeChecking.Monad.Exception
import Agda.TypeChecking.Monad.Context

import Agda.TypeChecking.Rules.LHS.Unify
import Agda.TypeChecking.Rules.LHS.Instantiate
import Agda.TypeChecking.Rules.LHS
import qualified Agda.TypeChecking.Rules.LHS.Split as Split

import Agda.TypeChecking.Coverage.Match
import Agda.TypeChecking.Coverage.SplitTree

import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Primitive (constructorForm)
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Irrelevance

import Agda.Interaction.Options

import Agda.Utils.Permutation
import Agda.Utils.Size
import Agda.Utils.Tuple
import Agda.Utils.Monad

#include "../undefined.h"
import Agda.Utils.Impossible

data SplitClause = SClause
      { scTel   :: Telescope      -- ^ type of variables in scPats
      , scPerm  :: Permutation    -- ^ how to get from the variables in the patterns to the telescope
      , scPats  :: [Arg Pattern]
      , scSubst :: [Term]         -- ^ substitution from scTel to old context
      }

-- type Covering = [SplitClause]

-- | A @Covering@ is the result of splitting a 'SplitClause'.
data Covering = Covering
  { covSplitArg     :: Nat  -- ^ De Bruijn level of argument we split on.
  , covSplitClauses :: [(QName, SplitClause)]
      -- ^ Covering clauses, indexed by constructor these clauses share.
  }

-- | Project the split clauses out of a covering.
splitClauses :: Covering -> [SplitClause]
splitClauses (Covering _ qcs) = map snd qcs

data SplitError = NotADatatype (Closure Type) -- ^ neither data type nor record
                | IrrelevantDatatype (Closure Type)   -- ^ data type, but in irrelevant position
                | CoinductiveDatatype (Closure Type)  -- ^ coinductive data type
{- UNUSED
                | NoRecordConstructor Type  -- ^ record type, but no constructor
 -}
                | CantSplit QName Telescope Args Args [Term]
                | GenericSplitError String
  deriving (Show)

instance PrettyTCM SplitError where
  prettyTCM err = case err of
    NotADatatype t -> enterClosure t $ \ t -> fsep $
      pwords "Cannot pattern match on non-datatype" ++ [prettyTCM t]
    IrrelevantDatatype t -> enterClosure t $ \ t -> fsep $
      pwords "Cannot pattern match on datatype" ++ [prettyTCM t] ++
      pwords "since it is declared irrelevant"
    CoinductiveDatatype t -> enterClosure t $ \ t -> fsep $
      pwords "Cannot pattern match on the coinductive type" ++ [prettyTCM t]
{- UNUSED
    NoRecordConstructor t -> fsep $
      pwords "Cannot pattern match on record" ++ [prettyTCM t] ++
      pwords "because it has no constructor"
 -}
    CantSplit c tel cIxs gIxs flex -> addCtxTel tel $ vcat
      [ fsep $ pwords "Cannot decide whether there should be a case for the constructor" ++ [prettyTCM c <> text ","] ++
               pwords "since the unification gets stuck on unifying the inferred indices"
      , nest 2 $ prettyTCM cIxs
      , fsep $ pwords "with the expected indices"
      , nest 2 $ prettyTCM gIxs
      ]
    GenericSplitError s -> fsep $
      pwords "Split failed:" ++ pwords s

instance Error SplitError where
  noMsg  = strMsg ""
  strMsg = GenericSplitError

type CoverM = ExceptionT SplitError TCM

{- UNUSED
typeOfVar :: Telescope -> Nat -> Dom Type
typeOfVar tel n
  | n >= len  = __IMPOSSIBLE__
  | otherwise = fmap snd  -- throw away name, keep Arg Type
                  $ ts !! fromIntegral (len - 1 - n)
  where
    len = genericLength ts
    ts  = telToList tel
-}

-- | Top-level function for checking pattern coverage.
checkCoverage :: QName -> TCM ()
checkCoverage f = do
  d <- getConstInfo f
  TelV gamma _ <- telView $ defType d
  let defn = theDef d
  case defn of
    Function{ funProjection = Just _ } -> __IMPOSSIBLE__
    Function{ funProjection = proj, funClauses = cs@(_:_) } -> do
      let -- n             = arity (does not include np)
          -- np            = number of dropped arguments due to projection-likeness
          -- lgamma/gamma' = telescope of non-dropped arguments
          -- xs            = variable patterns fitting lgamma
          n            = genericLength $ clausePats $ head cs
          np           = maybe 0 snd proj
          lgamma       = genericTake n $ genericDrop np $ telToList gamma
          gamma'       = telFromList lgamma
          xs           = map (argFromDom . fmap (const $ VarP "_")) $ lgamma
      reportSDoc "tc.cover.top" 10 $ vcat
        [ text "Coverage checking"
        , nest 2 $ vcat $ map (text . show . clausePats) cs
        ]
      -- used = actually used clauses for cover
      -- pss  = uncovered cases
      (splitTree, used, pss) <- cover cs $ SClause gamma' (idP n) xs (idSub gamma')
      reportSDoc "tc.cover.splittree" 10 $ vcat
        [ text "generated split tree for" <+> prettyTCM f
        , text $ show splitTree
        ]
      whenM (optCompletenessCheck <$> pragmaOptions) $
        -- report an error if there are uncovered cases
        unless (null pss) $
            setCurrentRange (getRange cs) $
              typeError $ CoverageFailure f pss
      -- is = indices of unreachable clauses
      let is = Set.toList $ Set.difference (Set.fromList [0..genericLength cs - 1]) used
      -- report an error if there are unreachable clauses
      unless (null is) $ do
          let unreached = map (cs !!) is
          setCurrentRange (getRange unreached) $
            typeError $ UnreachableClauses f (map clausePats unreached)
    _             -> __IMPOSSIBLE__

-- | @cover cs (SClause _ _ ps _) = return (splitTree, used, pss)@.
--   checks that the list of clauses @cs@ covers the given split clause.
--   Returns the @splitTree@, the @used@ clauses, and missing cases @pss@.
cover :: [Clause] -> SplitClause -> TCM (SplitTree, Set Nat, [[Arg Pattern]])
cover cs (SClause tel perm ps _) = do
  reportSDoc "tc.cover.cover" 10 $ vcat
    [ text "checking coverage of pattern:"
    , nest 2 $ text "tel  =" <+> prettyTCM tel
    , nest 2 $ text "perm =" <+> text (show perm)
    , nest 2 $ text "ps   =" <+> text (show ps)
    ]
  case match cs ps perm of
    Yes i          -> do
      reportSLn "tc.cover.cover" 10 $ "pattern covered by clause " ++ show i
      -- Check if any earlier clauses could match with appropriate literals
      let is = [ j | (j, c) <- zip [0..i-1] cs, matchLits c ps perm ]
      -- OLD: let is = [ j | (j, c) <- zip [0..] (genericTake i cs), matchLits c ps perm ]
      reportSLn "tc.cover.cover"  10 $ "literal matches: " ++ show is
      return (SplittingDone, Set.fromList (i : is), [])
    No       -> return (SplittingDone, Set.empty, [ps])
    Block xs -> do
      -- xs is a non-empty lists of blocking variables
      -- try splitting on one of them
      r <- altM1 (split Inductive tel perm ps) xs
      case r of
        Left err  -> case err of
          CantSplit c tel us vs _ -> typeError $ CoverageCantSplitOn c tel us vs
          NotADatatype a          -> enterClosure a $ typeError . CoverageCantSplitType
          IrrelevantDatatype a    -> enterClosure a $ typeError . CoverageCantSplitIrrelevantType
          CoinductiveDatatype a   -> enterClosure a $ typeError . CoverageCantSplitType
{- UNUSED
          NoRecordConstructor a   -> typeError $ CoverageCantSplitType a
 -}
          GenericSplitError s     -> fail $ "failed to split: " ++ s
        Right (Covering n scs) -> do
          (trees, useds, psss) <- unzip3 <$> mapM (cover cs) (map snd scs)
          let tree = SplitAt n $ zipWith (\ (q,_) t -> (q,t)) scs trees
          return (tree, Set.unions useds, concat psss)

-- | Check that a type is a non-irrelevant datatype or a record with
-- named constructor. Unless the 'Induction' argument is 'CoInductive'
-- the data type must be inductive.
isDatatype :: (MonadTCM tcm, MonadException SplitError tcm) =>
              Induction -> Dom Type ->
              tcm (QName, [Arg Term], [Arg Term], [QName])
isDatatype ind at = do
  let t       = unDom at
      throw f = throwException . f =<< do liftTCM $ buildClosure t
  t' <- liftTCM $ reduce t
  case ignoreSharing $ unEl t' of
    Def d args -> do
      def <- liftTCM $ theDef <$> getConstInfo d
      splitOnIrrelevantDataAllowed <- liftTCM $ optExperimentalIrrelevance <$> pragmaOptions
      case def of
        Datatype{dataPars = np, dataCons = cs, dataInduction = i}
          | i == CoInductive && ind /= CoInductive ->
              throw CoinductiveDatatype
          -- Andreas, 2011-10-03 allow some splitting on irrelevant data (if only one constr. matches)
          | domRelevance at == Irrelevant && not splitOnIrrelevantDataAllowed ->
              throw IrrelevantDatatype
          | otherwise -> do
              let (ps, is) = genericSplitAt np args
              return (d, ps, is, cs)
        Record{recPars = np, recCon = c} ->
          return (d, args, [], [c])
        _ -> throw NotADatatype
    _ -> throw NotADatatype

-- | @computeNeighbourhood delta1 delta2 perm d pars ixs hix hps con@
--
--   @
--      delta1   Telescope before split point
--      n        Name of pattern variable at split point
--      delta2   Telescope after split point
--      d        Name of datatype to split at
--      pars     Data type parameters
--      ixs      Data type indices
--      hix      ??
--      hps      Patterns with hole at split point
--      con      Constructor to fit into hole
--   @
--   @dtype == d pars ixs@
computeNeighbourhood :: Telescope -> String -> Telescope -> Permutation -> QName -> Args -> Args -> Nat -> OneHolePatterns -> QName -> CoverM [SplitClause]
computeNeighbourhood delta1 n delta2 perm d pars ixs hix hps con = do

  -- Get the type of the datatype
  dtype <- liftTCM $ (`piApply` pars) . defType <$> getConstInfo d

  -- Get the real constructor name
  Con con [] <- liftTCM $ ignoreSharing <$> (constructorForm =<< normalise (Con con []))

  -- Get the type of the constructor
  ctype <- liftTCM $ defType <$> getConstInfo con

  -- Lookup the type of the constructor at the given parameters
  (gamma0, cixs) <- do
    TelV gamma0 (El _ d) <- liftTCM $ telView (ctype `piApply` pars)
    let Def _ cixs = ignoreSharing d
    return (gamma0, cixs)

  -- Andreas, 2012-02-25 preserve name suggestion for recursive arguments
  -- of constructor

  let preserve (x, t@(El _ (Def d' _))) | d == d' = (n, t)
      preserve (x, (El s (Shared p))) = preserve (x, El s $ derefPtr p)
      preserve p = p
      gamma = telFromList . map (fmap preserve) . telToList $ gamma0

  debugInit con ctype pars ixs cixs delta1 delta2 gamma hps hix

  -- All variables are flexible
  let flex = [0..size delta1 + size gamma - 1]

  -- Unify constructor target and given type (in Δ₁Γ)
  let conIxs   = drop (size pars) cixs
      givenIxs = raise (size gamma) ixs

  r <- addCtxTel (delta1 `abstract` gamma) $
       unifyIndices flex (raise (size gamma) dtype) conIxs givenIxs

  case r of
    NoUnify _ _ _ -> do
      debugNoUnify
      return []
    DontKnow _    -> do
      debugCantSplit
      throwException $ CantSplit con (delta1 `abstract` gamma) conIxs givenIxs
                                 [ Var i [] | i <- flex ]
    Unifies sub   -> do
      debugSubst "sub" sub

      -- Substitute the constructor for x in Δ₂: Δ₂' = Δ₂[conv/x]
      let conv    = Con con  $ teleArgs gamma   -- Θ Γ ⊢ conv (for any Θ)
          delta2' = subst conv $ raiseFrom 1 (size gamma) delta2
      debugTel "delta2'" delta2'

      -- Compute a substitution ρ : Δ₁ΓΔ₂' → Δ₁(x:D)Δ₂
      let rho = [ Var i [] | i <- [0..size delta2' - 1] ]
             ++ [ raise (size delta2') conv ]
             ++ [ Var i [] | i <- [size delta2' + size gamma ..] ]

      -- Plug the hole with the constructor and apply ρ
      -- TODO: Is it really correct to use Nothing here?
      let conp = ConP con Nothing $ map (fmap VarP) $ teleArgNames gamma
          ps   = plugHole conp hps
          ps'  = substs rho ps      -- Δ₁ΓΔ₂' ⊢ ps'
      debugPlugged ps ps'

      -- Δ₁Γ ⊢ sub, we need something in Δ₁ΓΔ₂'
      -- Also needs to be padded with Nothing's to have the right length.
      let pad n xs x = xs ++ replicate (max 0 $ n - size xs) x
          sub'       = replicate (size delta2') Nothing ++
                       pad (size delta1 + size gamma) (raise (size delta2') sub) Nothing
      debugSubst "sub'" sub'

      -- Θ = Δ₁ΓΔ₂'
      let theta = delta1 `abstract` gamma `abstract` delta2'
      debugTel "theta" theta

      -- Apply the unifying substitution to Θ
      -- We get ρ' : Θ' -> Θ
      --        π  : Θ' -> Θ
      (theta', iperm, rho', _) <- liftTCM $ instantiateTel sub' theta
      debugTel "theta'" theta'
      debugShow "iperm" iperm

      -- Compute final permutation
      let perm' = expandP hix (size gamma) perm -- perm' : Θ -> Δ₁(x : D)Δ₂
          rperm = iperm `composeP` perm'
      debugShow "perm'" perm'
      debugShow "rperm" rperm

      -- Compute the final patterns
      let ps'' = instantiatePattern sub' perm' ps'
          rps  = substs rho' ps''

      -- Compute the final substitution
      let rsub  = substs rho' rho

      debugFinal theta' rperm rps

      return [SClause theta' rperm rps rsub]

  where
    debugInit con ctype pars ixs cixs delta1 delta2 gamma hps hix =
      liftTCM $ reportSDoc "tc.cover.split.con" 20 $ vcat
        [ text "computeNeighbourhood"
        , nest 2 $ vcat
          [ text "con    =" <+> prettyTCM con
          , text "ctype  =" <+> prettyTCM ctype
          , text "hps    =" <+> text (show hps)
          , text "pars   =" <+> prettyList (map prettyTCM pars)
          , text "ixs    =" <+> addCtxTel (delta1 `abstract` gamma) (prettyList (map prettyTCM ixs))
          , text "cixs   =" <+> prettyList (map prettyTCM cixs)
          , text "delta1 =" <+> prettyTCM delta1
          , text "delta2 =" <+> prettyTCM delta2
          , text "gamma  =" <+> prettyTCM gamma
          , text "hix    =" <+> text (show hix)
          ]
        ]

    debugNoUnify =
      liftTCM $ reportSLn "tc.cover.split.con" 20 "  Constructor impossible!"

    debugCantSplit =
      liftTCM $ reportSLn "tc.cover.split.con" 20 "  Bad split!"

    debugSubst s sub =
      liftTCM $ reportSDoc "tc.cover.split.con" 20 $ nest 2 $ vcat
        [ text (s ++ " =") <+> brackets (fsep $ punctuate comma $ map (maybe (text "_") prettyTCM) sub)
        ]

    debugTel s tel =
      liftTCM $ reportSDoc "tc.cover.split.con" 20 $ nest 2 $ vcat
        [ text (s ++ " =") <+> prettyTCM tel
        ]

    debugShow s x =
      liftTCM $ reportSDoc "tc.cover.split.con" 20 $ nest 2 $ vcat
        [ text (s ++ " =") <+> text (show x)
        ]

    debugPlugged ps ps' =
      liftTCM $ reportSDoc "tc.cover.split.con" 20 $ nest 2 $ vcat
        [ text "ps     =" <+> text (show ps)
        , text "ps'    =" <+> text (show ps')
        ]

    debugFinal tel perm ps =
      liftTCM $ reportSDoc "tc.cover.split.con" 20 $ nest 2 $ vcat
        [ text "rtel   =" <+> prettyTCM tel
        , text "rperm  =" <+> text (show perm)
        , text "rps    =" <+> text (show ps)
        ]

-- | split Δ x ps. Δ ⊢ ps, x ∈ Δ (deBruijn index)
splitClause :: Clause -> Nat -> TCM (Either SplitError Covering)
splitClause c x =
  split Inductive (clauseTel c) (clausePerm c) (clausePats c) x

splitClauseWithAbs :: Clause -> Nat -> TCM (Either SplitError (Either SplitClause Covering))
splitClauseWithAbs c x =
  split' Inductive (clauseTel c) (clausePerm c) (clausePats c) x

split :: Induction
         -- ^ Coinductive constructors are allowed if this argument is
         -- 'CoInductive'.
      -> Telescope -> Permutation -> [Arg Pattern] -> Nat
      -> TCM (Either SplitError Covering)
split ind tel perm ps x = do
  r <- split' ind tel perm ps x
  return $ case r of
    Left err        -> Left err
    Right (Left _)  -> Right $ Covering (dbIndexToLevel tel x) []
    Right (Right c) -> Right c

-- | Convert a de Bruijn index relative to a telescope to a de Buijn level.
--   The result should be the argument (counted from left, starting with 0)
--   to split at.
dbIndexToLevel tel x = if n < 0 then __IMPOSSIBLE__ else n
  where n = size tel - x - 1 -- Andreas: do we need to permute?

split' :: Induction
          -- ^ Coinductive constructors are allowed if this argument is
          -- 'CoInductive'.
       -> Telescope -> Permutation -> [Arg Pattern] -> Nat
       -> TCM (Either SplitError (Either SplitClause Covering))
split' ind tel perm ps x = liftTCM $ runExceptionT $ do

  debugInit tel perm x ps

  -- Split the telescope at the variable
  -- t = type of the variable,  Δ₁ ⊢ t
  (n, t, delta1, delta2) <- do
    let (tel1, Dom h r (n, t) : tel2) = genericSplitAt (size tel - x - 1) $ telToList tel
    return (n, Dom h r t, telFromList tel1, telFromList tel2)

  -- Compute the one hole context of the patterns at the variable
  (hps, hix) <- do
    let holes = reverse $ permute perm $ zip [0..] $ allHolesWithContents ps
    unless (length holes == length (telToList tel)) $
      fail "split: bad holes or tel"

    -- There is always a variable at the given hole.
    let (hix, (VarP s, hps)) = holes !! x
    debugHoleAndType delta1 delta2 s hps t

    return (hps, hix)

  -- Check that t is a datatype or a record
  -- Andreas, 2010-09-21, isDatatype now directly throws an exception if it fails
  -- cons = constructors of this datatype
  (d, pars, ixs, cons) <- inContextOfT $ isDatatype ind t

  liftTCM $ whenM (optWithoutK <$> pragmaOptions) $
    inContextOfT $ Split.wellFormedIndices (unDom t)

  -- Compute the neighbourhoods for the constructors
  ns <- concat <$> mapM (\ con -> map (con,) <$> computeNeighbourhood delta1 n delta2 perm d pars ixs hix hps con) cons
  case ns of
    []  -> do
      let absurd = VarP "()"
      return $ Left $ SClause
               { scTel  = telFromList $ telToList delta1 ++
                                        [fmap ((,) "()") t] ++ -- add name "()"
                                        telToList delta2
               , scPerm = perm
               , scPats = plugHole absurd hps
               , scSubst = [] -- not used anyway
               }

    -- Andreas, 2011-10-03
    -- if more than one constructor matches, we cannot be irrelevant
    -- (this piece of code is unreachable if --experimental-irrelevance is off)
    (_ : _ : _) | unusableRelevance (domRelevance t) ->
      throwException . IrrelevantDatatype =<< do liftTCM $ buildClosure (unDom t)

    _   -> return $ Right $ Covering xDBLevel ns

  where
    xDBLevel = dbIndexToLevel tel x

    inContextOfT :: MonadTCM tcm => tcm a -> tcm a
    inContextOfT = addCtxTel tel . escapeContext (x + 1)

    inContextOfDelta2 :: MonadTCM tcm => tcm a -> tcm a
    inContextOfDelta2 = addCtxTel tel . escapeContext x

    -- Debug printing
    debugInit tel perm x ps =
      liftTCM $ reportSDoc "tc.cover.top" 10 $ vcat
        [ text "TypeChecking.Coverage.split': split"
        , nest 2 $ vcat
          [ text "tel     =" <+> prettyTCM tel
          , text "perm    =" <+> text (show perm)
          , text "x       =" <+> text (show x)
          , text "ps      =" <+> text (show ps)
          ]
        ]

    debugHoleAndType delta1 delta2 s hps t =
      liftTCM $ reportSDoc "tc.cover.top" 10 $ nest 2 $ vcat $
        [ text "p      =" <+> text s
        , text "hps    =" <+> text (show hps)
        , text "delta1 =" <+> prettyTCM delta1
        , text "delta2 =" <+> inContextOfDelta2 (prettyTCM delta2)
        , text "t      =" <+> inContextOfT (prettyTCM t)
        ]
