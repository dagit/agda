{-# OPTIONS -cpp #-}

module TypeChecking.Rules.LHS.Instantiate where

import Syntax.Common
import Syntax.Internal
import qualified Syntax.Abstract as A

import TypeChecking.Monad
import TypeChecking.Substitute
import TypeChecking.Free
import TypeChecking.Pretty

import TypeChecking.Rules.LHS.Problem
import TypeChecking.Rules.LHS.Split ( asView )

import Utils.Permutation
import Utils.Size

#include "../../../undefined.h"

-- | The permutation should permute the corresponding telescope. (left-to-right list)
rename :: Subst t => Permutation -> t -> t
rename p = substs (renaming p)

-- | If @permute π : [a]Γ -> [a]Δ@, then @substs (renaming π) : Term Γ -> Term Δ@
renaming :: Permutation -> [Term]
renaming p = gamma'
  where
    n	   = size p
    gamma  = permute (reverseP $ invertP $ reverseP p) $ map var [0..]
    gamma' = gamma ++ map var [n..]
    var i  = Var i []

-- | If @permute π : [a]Γ -> [a]Δ@, then @substs (renamingR π) : Term Δ -> Term Γ@
renamingR :: Permutation -> [Term]
renamingR p@(Perm n _) = permute (reverseP p) (map var [0..]) ++ map var [n..]
  where
    var i  = Var i []

-- | Instantiate a telescope with a substitution. Might reorder the telescope.
--   @instantiateTel (Γ : Tel)(σ : Γ --> Γ) = Γσ~@
--   Monadic only for debugging purposes.
instantiateTel :: Substitution -> Telescope -> TCM (Telescope, Permutation, [Term], [Type])
instantiateTel s tel = do

  reportSDoc "tc.lhs.inst" 10 $ sep
    [ text "instantiateTel "
    , nest 2 $ fsep $ punctuate comma $ map (maybe (text "_") prettyTCM) s
    , nest 2 $ prettyTCM tel
    ]

  -- Shrinking permutation (removing Justs) (and its complement, and reverse)
  let ps  = Perm (size s) [ i | (i, Nothing) <- zip [0..] $ reverse s ]
      psR = reverseP ps
      psC = Perm (size s) [ i | (i, Just _)  <- zip [0..] $ reverse s ]

  reportS "tc.lhs.inst" 10 $ unlines
    [ "ps  = " ++ show ps
    , "psR = " ++ show psR
    , "psC = " ++ show psC
    ]

  -- s' : Substitution Γσ
  let s' = rename psR s

  reportSDoc "tc.lhs.inst" 15 $ nest 2 $ 
    text "s'   =" <+> fsep (punctuate comma $ map (maybe (text "_") prettyTCM) s')

  -- rho : [Tm Γσ]Γ
  let rho = mkSubst s'

  -- tel1 : [Type Γ]Γ
  let tel1   = flattenTel tel
      names1 = map (fst . unArg) $ telToList tel

  reportSDoc "tc.lhs.inst" 15 $ nest 2 $ 
    text "tel1 =" <+> brackets (fsep $ punctuate comma $ map prettyTCM tel1)

  -- tel2 : [Type Γσ]Γ
  let tel2 = substs rho tel1

  reportSDoc "tc.lhs.inst" 15 $ nest 2 $ 
    text "tel2 =" <+> brackets (fsep $ punctuate comma $ map prettyTCM tel2)

  -- tel3 : [Type Γσ]Γσ
  let tel3   = permute ps tel2
      names3 = permute ps names1

  reportSDoc "tc.lhs.inst" 15 $ nest 2 $ 
    text "tel3 =" <+> brackets (fsep $ punctuate comma $ map prettyTCM tel3)

  -- p : Permutation (Γσ -> Γσ~)
  let p = reorderTel tel3

  reportSLn "tc.lhs.inst" 10 $ "p   = " ++ show p

  -- rho' : [Term Γσ~]Γσ
  let rho' = renaming (reverseP p)

  -- tel4 : [Type Γσ~]Γσ~
  let tel4   = substs rho' (permute p tel3)
      names4 = permute p names3

  reportSDoc "tc.lhs.inst" 15 $ nest 2 $ 
    text "tel4 =" <+> brackets (fsep $ punctuate comma $ map prettyTCM tel4)

  -- tel5 = Γσ~
  let tel5 = unflattenTel names4 tel4

  reportSDoc "tc.lhs.inst" 15 $ nest 2 $ 
    text "tel5 =" <+> prettyTCM tel5

  -- remember the types of the instantiations
  -- itypes : [Type Γσ~]Γ*
  let itypes = substs rho' $ permute psC $ map unArg tel2

  return (tel5, composeP p ps, substs rho' rho, itypes)
  where

    -- Turn a Substitution ([Maybe Term]) into a substitution ([Term])
    -- (The result is an infinite list)
    mkSubst :: [Maybe Term] -> [Term]
    mkSubst s = rho 0 s'
      where s'  = s ++ repeat Nothing
	    rho i (Nothing : s) = Var i [] : rho (i + 1) s
	    rho i (Just u  : s) = u : rho i s
	    rho _ []		= __IMPOSSIBLE__

    -- Flatten telescope: (Γ : Tel) -> [Type Γ]
    flattenTel :: Telescope -> [Arg Type]
    flattenTel EmptyTel		 = []
    flattenTel (ExtendTel a tel) = raise (size tel + 1) a : flattenTel (absBody tel)

    -- Reorder: Γ -> Permutation (Γ -> Γ~)
    reorderTel :: [Arg Type] -> Permutation
    reorderTel tel = case topoSort comesBefore tel' of
      Nothing -> __IMPOSSIBLE__
      Just p  -> p
      where
	tel' = reverse $ zip [0..] $ reverse tel
	(i, _) `comesBefore` (_, a) = i `freeIn` a

    -- Unflatten: turns a flattened telescope into a proper telescope.
    unflattenTel :: [String] -> [Arg Type] -> Telescope
    unflattenTel []	  []	    = EmptyTel
    unflattenTel (x : xs) (a : tel) = ExtendTel a' (Abs x tel')
      where
	tel' = unflattenTel xs tel
	a'   = substs rho a
	rho  = replicate (size tel + 1) __IMPOSSIBLE__ ++ map var [0..]
	  where var i = Var i []
    unflattenTel [] (_ : _) = __IMPOSSIBLE__
    unflattenTel (_ : _) [] = __IMPOSSIBLE__

-- | Produce a nice error message when splitting failed
nothingToSplitError :: Problem -> TCM a
nothingToSplitError (Problem ps _ tel) = splitError ps tel
  where
    splitError []	EmptyTel    = __IMPOSSIBLE__
    splitError (_:_)	EmptyTel    = __IMPOSSIBLE__
    splitError []	ExtendTel{} = __IMPOSSIBLE__
    splitError (p : ps) (ExtendTel a tel)
      | isBad p   = traceCall (CheckPattern (strip p) EmptyTel (unArg a)) $ case strip p of
	  A.DotP _ e -> typeError $ UninstantiatedDotPattern e
	  p	     -> typeError $ IlltypedPattern p (unArg a)
      | otherwise = underAbstraction a tel $ \tel -> splitError ps tel
      where
	strip = snd . asView . namedThing . unArg
	isBad p = case strip p of
	  A.DotP _ _   -> True
	  A.ConP _ _ _ -> True
	  A.LitP _     -> True
	  _	       -> False

