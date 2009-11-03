
module Agda.TypeChecking.MetaVars.Occurs where

import Control.Applicative
import Control.Monad

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Reduce

-- | Extended occurs check.
class Occurs t where
  occurs :: (TypeError -> TCM ()) -> MetaId -> [Nat] -> t -> TCM t

occursCheck :: (MonadTCM tcm, Occurs a) => MetaId -> [Nat] -> a -> tcm a
occursCheck m xs = liftTCM . occurs typeError m xs

instance Occurs Term where
    occurs abort m xs v = do
	v <- reduceB v
	case v of
	    -- Don't fail on blocked terms or metas
	    Blocked _ v          -> occurs' (const patternViolation) v
	    NotBlocked v         -> occurs' abort v
	where
	    occurs' abort v = case v of
		Var i vs   -> do
		  unless (i `elem` xs) $ abort $ MetaCannotDependOn m xs i
		  Var i <$> occ vs
		Lam h f	    -> Lam h <$> occ f
		Lit l	    -> return v
		Def c vs    -> Def c <$> occ vs
		Con c vs    -> Con c <$> occ vs
		Pi a b	    -> uncurry Pi <$> occ (a,b)
		Fun a b	    -> uncurry Fun <$> occ (a,b)
		Sort s	    -> Sort <$> occ s
		MetaV m' vs -> do
		    when (m == m') $ abort $ MetaOccursInItself m
		    -- Don't fail on flexible occurrence
		    MetaV m' <$> occurs (const patternViolation) m xs vs
		where
		    occ x = occurs abort m xs x

instance Occurs Type where
    occurs abort m xs (El s v) = uncurry El <$> occurs abort m xs (s,v)

instance Occurs Sort where
    occurs abort m xs s =
	do  s' <- reduce s
	    case s' of
		MetaS m' args -> do
		  when (m == m') $ abort $ MetaOccursInItself m
		  MetaS m' <$> occurs (const patternViolation) m xs args
		Lub s1 s2  -> uncurry Lub <$> occurs abort m xs (s1,s2)
                DLub s1 s2 -> uncurry DLub <$> occurs abort m xs (s1, s2)
		Suc s      -> Suc <$> occurs abort m xs s
		Type a     -> Type <$> occurs abort m xs a
		Prop       -> return s'
		Inf        -> return s'

instance Occurs a => Occurs (Abs a) where
    occurs abort m xs (Abs s x) = Abs s <$> occurs abort m (0 : map (1+) xs) x

instance Occurs a => Occurs (Arg a) where
    occurs abort m xs (Arg h x) = Arg h <$> occurs abort m xs x

instance (Occurs a, Occurs b) => Occurs (a,b) where
    occurs abort m xs (x,y) = (,) <$> occurs abort m xs x <*> occurs abort m xs y

instance Occurs a => Occurs [a] where
    occurs abort m xs ys = mapM (occurs abort m xs) ys

