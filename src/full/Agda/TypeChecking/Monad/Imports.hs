
module Agda.TypeChecking.Monad.Imports where

import Control.Monad.State
import Control.Monad.Reader

import Data.Map (Map)
import Data.Set (Set)
import qualified Data.Map as Map
import qualified Data.List as List
import qualified Data.Set as Set

import System.Time

import Agda.Syntax.Abstract.Name
import Agda.TypeChecking.Monad.Base
import Agda.Utils.Monad

addImport :: ModuleName -> TCM ()
addImport m =
    modify $ \s -> s { stImportedModules = Set.insert m $ stImportedModules s }

addImportCycleCheck :: ModuleName -> TCM a -> TCM a
addImportCycleCheck m =
    local $ \e -> e { envImportPath = m : envImportPath e }

getImports :: TCM (Set ModuleName)
getImports = gets stImportedModules

isImported :: ModuleName -> TCM Bool
isImported m = Set.member m <$> getImports

getImportPath :: TCM [ModuleName]
getImportPath = asks envImportPath

visitModule :: ModuleName -> Interface -> ClockTime -> TCM ()
visitModule x i t = modify $ \s -> s { stVisitedModules = Map.insert x (i,t) $ stVisitedModules s }

setVisitedModules :: VisitedModules -> TCM ()
setVisitedModules ms = modify $ \s -> s { stVisitedModules = ms }

getVisitedModules :: TCM VisitedModules
getVisitedModules = gets stVisitedModules

isVisited :: ModuleName -> TCM Bool
isVisited x = gets $ Map.member x . stVisitedModules

getVisitedModule :: ModuleName -> TCM (Maybe (Interface, ClockTime))
getVisitedModule x = gets $ Map.lookup x . stVisitedModules

getDecodedModules :: TCM DecodedModules
getDecodedModules = gets stDecodedModules

setDecodedModules :: DecodedModules -> TCM ()
setDecodedModules ms = modify $ \s -> s { stDecodedModules = ms }

preserveDecodedModules :: TCM a -> TCM a
preserveDecodedModules tcm = do ms <- getDecodedModules
                                a  <- tcm
                                setDecodedModules ms
                                return a

getDecodedModule :: ModuleName -> TCM (Maybe (Interface, ClockTime))
getDecodedModule x = gets $ Map.lookup x . stDecodedModules

storeDecodedModule :: ModuleName -> Interface -> ClockTime -> TCM ()
storeDecodedModule x i t = modify $ \s -> s { stDecodedModules = Map.insert x (i,t) $ stDecodedModules s }

dropDecodedModule :: ModuleName -> TCM ()
dropDecodedModule x = modify $ \s -> s { stDecodedModules = Map.delete x $ stDecodedModules s }

withImportPath :: [ModuleName] -> TCM a -> TCM a
withImportPath path = local $ \e -> e { envImportPath = path }

-- | Assumes that the first module in the import path is the module we are
--   worried about.
checkForImportCycle :: TCM ()
checkForImportCycle = do
    m:ms <- getImportPath
    when (m `elem` ms) $ typeError $ CyclicModuleDependency
				   $ dropWhile (/= m) $ reverse (m:ms)

