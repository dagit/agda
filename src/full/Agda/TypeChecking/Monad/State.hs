
module Agda.TypeChecking.Monad.State where

import Control.Applicative
import Control.Monad.State
import Data.Set (Set)
import Data.Map
import qualified Data.Set as Set

import Agda.Syntax.Common
import Agda.Syntax.Scope.Base
import qualified Agda.Syntax.Concrete.Name as C
import Agda.Syntax.Abstract.Name

import Agda.TypeChecking.Monad.Base

import Agda.Utils.Hash

-- | Resets the non-persistent part of the type checking state.

resetState :: TCM ()
resetState = do
    pers <- stPersistent <$> get
    put $ initState { stPersistent = pers }

-- | Resets all of the type checking state.

resetAllState :: TCM ()
resetAllState = put initState

-- | Set the current scope.
setScope :: ScopeInfo -> TCM ()
setScope scope = modify $ \s -> s { stScope = scope }

-- | Get the current scope.
getScope :: TCM ScopeInfo
getScope = gets stScope

-- | Sets stExtLambdaTele .
setExtLambdaTele :: Map QName (Int , Int) -> TCM ()
setExtLambdaTele tele = modify $ \s -> s { stExtLambdaTele = tele }

-- | Get stExtLambdaTele.
getExtLambdaTele :: TCM (Map QName (Int , Int))
getExtLambdaTele = gets stExtLambdaTele

addExtLambdaTele :: QName -> (Int , Int) -> TCM ()
addExtLambdaTele id x = getExtLambdaTele >>= setExtLambdaTele . (insert id x)

-- | Modify the current scope.
modifyScope :: (ScopeInfo -> ScopeInfo) -> TCM ()
modifyScope f = do
  s <- getScope
  setScope $ f s

-- | Run a computation in a local scope.
withScope :: ScopeInfo -> TCM a -> TCM (a, ScopeInfo)
withScope s m = do
  s' <- getScope
  setScope s
  x   <- m
  s'' <- getScope
  setScope s'
  return (x, s'')

-- | Same as 'withScope', but discard the scope from the computation.
withScope_ :: ScopeInfo -> TCM a -> TCM a
withScope_ s m = fst <$> withScope s m

-- | Discard any changes to the scope by a computation.
localScope :: TCM a -> TCM a
localScope m = do
  scope <- getScope
  x <- m
  setScope scope
  return x

-- | Set the top-level module. This affects the global module id of freshly
--   generated names.

-- TODO: Is the hash-function collision-free? If not, then the
-- implementation of 'setTopLevelModule' should be changed.

setTopLevelModule :: C.QName -> TCM ()
setTopLevelModule x =
  modify $ \s -> s
    { stFreshThings = (stFreshThings s)
      { fName = NameId 0 $ hash (show x)
      }
    }

-- | Use a different top-level module for a computation. Used when generating
--   names for imported modules.
withTopLevelModule :: C.QName -> TCM a -> TCM a
withTopLevelModule x m = do
  next <- gets $ fName . stFreshThings
  setTopLevelModule x
  y <- m
  modify $ \s -> s { stFreshThings = (stFreshThings s) { fName = next } }
  return y

-- | Tell the compiler to import the given Haskell module.
addHaskellImport :: String -> TCM ()
addHaskellImport i =
  modify $ \s -> s { stHaskellImports = Set.insert i $ stHaskellImports s }

-- | Get the Haskell imports.
getHaskellImports :: TCM (Set String)
getHaskellImports = gets stHaskellImports
