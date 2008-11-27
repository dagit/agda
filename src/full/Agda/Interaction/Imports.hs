{-# LANGUAGE CPP #-}
{-| This modules deals with how to find imported modules and loading their
    interface files.
-}
module Agda.Interaction.Imports where

import Prelude hiding (catch)

import Control.Monad.Error
import Control.Monad.State
import qualified Data.Map as Map
import qualified Data.List as List
import qualified Data.Set as Set
import qualified Data.ByteString.Lazy as BS
import Data.Generics
import Data.List
import System.Directory
import System.Time
import Control.Exception
import qualified System.IO.UTF8 as UTF8

import qualified Agda.Syntax.Concrete.Name as C
import Agda.Syntax.Abstract.Name
import Agda.Syntax.Parser 
import Agda.Syntax.Scope.Base
import Agda.Syntax.Translation.ConcreteToAbstract

import Agda.Termination.TermCheck

import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Serialise
import Agda.TypeChecking.Primitive
import Agda.TypeChecker

import Agda.Interaction.Options
import Agda.Interaction.Highlighting.Generate
import Agda.Interaction.Highlighting.Emacs
import Agda.Interaction.Highlighting.Vim

import Agda.Utils.FileName
import Agda.Utils.Monad
import Agda.Utils.IO

import Agda.Utils.Impossible
#include "../undefined.h"

-- | Merge an interface into the current proof state.
mergeInterface :: Interface -> TCM ()
mergeInterface i = do
    let sig	= iSignature i
	builtin = Map.toList $ iBuiltin i
	prim	= [ x | (_,Prim x) <- builtin ]
	bi	= Map.fromList [ (x,Builtin t) | (x,Builtin t) <- builtin ]
    bs <- getBuiltinThings
    reportSLn "import.iface.merge" 10 $ "Merging interface"
    reportSLn "import.iface.merge" 20 $
      "  Current builtins " ++ show (Map.keys bs) ++ "\n" ++
      "  New builtins     " ++ show (Map.keys bi)
    case Map.toList $ Map.intersection bs bi of
      []               -> return ()
      (b, Builtin x):_ -> typeError $ DuplicateBuiltinBinding b x x
      (_, Prim{}):_    -> __IMPOSSIBLE__
    modify $ \st -> st { stImports	    = unionSignatures [stImports st, sig]
		       , stImportedBuiltins = stImportedBuiltins st `Map.union` bi
		       }
    reportSLn "import.iface.merge" 20 $
      "  Rebinding primitives " ++ show prim
    prim <- Map.fromList <$> mapM rebind prim
    modify $ \st -> st { stImportedBuiltins = stImportedBuiltins st `Map.union` prim
		       }
    where
	rebind x = do
	    PrimImpl _ pf <- lookupPrimitiveFunction x
	    return (x, Prim pf)

addImportedThings :: Signature -> BuiltinThings PrimFun -> TCM ()
addImportedThings isig ibuiltin =
  modify $ \st -> st
    { stImports          = unionSignatures [stImports st, isig]
    , stImportedBuiltins = Map.union (stImportedBuiltins st) ibuiltin
    }

-- TODO: move
data FileType = SourceFile | InterfaceFile

findFile :: FileType -> ModuleName -> TCM FilePath
findFile ft m = do
    let x = mnameToConcrete m
    dirs <- getIncludeDirs
    let files = [ dir ++ [slash] ++ file
		| dir  <- dirs
		, file <- map (moduleNameToFileName x) exts
		]
    files' <- liftIO $ filterM doesFileExist files
    files' <- liftIO $ nubFiles files'
    case files' of
	[]	-> typeError $ FileNotFound m files
	file:_	-> return file
    where
	exts = case ft of
		SourceFile    -> [".agda", ".lagda", ".agda2", ".lagda2", ".ag2"]
		InterfaceFile -> [".agdai", ".ai"]

scopeCheckImport :: ModuleName -> TCM Scope
scopeCheckImport x = do
    reportSLn "import.scope" 5 $ "Scope checking " ++ show x
    visited <- Map.keys <$> getVisitedModules
    reportSLn "import.scope" 10 $ "  visited: " ++ show visited
    (i,t)   <- getInterface x
    addImport x
    return $ iScope i

alreadyVisited :: ModuleName -> TCM (Interface, ClockTime) -> TCM (Interface, ClockTime)
alreadyVisited x getIface = do
    mm <- getVisitedModule x
    case mm of
	Just it	-> do
            reportSLn "import.visit" 10 $ "  Already visited " ++ show x
            return it
	Nothing	-> do
	    reportSLn "import.visit" 5 $ "  Getting interface for " ++ show x
	    (i, t) <- getIface
	    reportSLn "import.visit" 5 $ "  Now we've looked at " ++ show x
	    visitModule x i t
	    return (i, t)

getInterface :: ModuleName -> TCM (Interface, ClockTime)
getInterface x = alreadyVisited x $ addImportCycleCheck x $ do
    file   <- findFile SourceFile x	-- requires source to exist
    let ifile = setExtension ".agdai" file

    reportSLn "import.iface" 10 $ "  Check for cycle"
    checkForImportCycle

    uptodate <- ifM ignoreInterfaces
		    (return False)
		    (liftIO $ ifile `isNewerThan` file)

    reportSLn "import.iface" 5 $ "  " ++ show x ++ " is " ++ (if uptodate then "" else "not ") ++ "up-to-date."

    (i,t) <- if uptodate
	then skip x ifile file
	else typeCheck ifile file

    visited <- isVisited x
    reportSLn "import.iface" 5 $ if visited then "  We've been here. Don't merge."
			         else "  New module. Let's check it out."
    unless visited $ mergeInterface i

    storeDecodedModule x i t
    return (i,t)

    where
	skip x ifile file = do

	    -- Examine the mtime of the interface file. If it is newer than the
	    -- stored version (in stDecodedModules), or if there is no stored version,
	    -- read and decode it. Otherwise use the stored version.
	    t  <- liftIO $ getModificationTime ifile
	    mm <- getDecodedModule x
	    mi <- case mm of
		      Just (im, tm) ->
			 if tm < t
			 then do dropDecodedModule x
				 reportSLn "import.iface" 5 $ "  file is newer, re-reading " ++ ifile
				 liftIO $ readInterface ifile
			 else do reportSLn "import.iface" 5 $ "  using stored version of " ++ ifile
				 return (Just im)
		      Nothing ->
			 do reportSLn "import.iface" 5 $ "  no stored version, reading " ++ ifile
			    liftIO $ readInterface ifile

	    -- Check that it's the right version
	    case mi of
		Nothing	-> do
		    reportSLn "import.iface" 5 $ "  bad interface, re-type checking"
		    typeCheck ifile file
		Just i	-> do

		    reportSLn "import.iface" 5 $ "  imports: " ++ show (iImportedModules i)

		    ts <- map snd <$> mapM getInterface (iImportedModules i)

		    -- If any of the imports are newer we need to retype check
		    if any (> t) ts
			then do
			    -- liftIO close	-- Close the interface file. See above.
			    typeCheck ifile file
			else do
			    reportSLn "" 1 $ "Skipping " ++ show x ++ " ( " ++ ifile ++ " )"
			    return (i, t)

	typeCheck ifile file = do

	    -- Do the type checking
	    reportSLn "" 1 $ "Checking " ++ show x ++ " ( " ++ file ++ " )"
	    ms       <- getImportPath
	    vs       <- getVisitedModules
	    ds       <- getDecodedModules
	    opts     <- commandLineOptions
	    trace    <- getTrace
            isig     <- getImportedSignature
            ibuiltin <- gets stImportedBuiltins
	    r  <- liftIO $ createInterface opts trace ms vs ds isig ibuiltin x file

	    -- Write interface file and return
	    case r of
		Left err -> throwError err
		Right (vs, ds, i, isig, ibuiltin)  -> do
		    liftIO $ writeInterface ifile i
                    -- writeInterface may remove ifile.
		    t <- liftIO $ ifM (doesFileExist ifile)
                           (getModificationTime ifile)
                           getClockTime
		    setVisitedModules vs
		    setDecodedModules ds
                    -- We need to add things imported when checking
                    -- the imported modules.
                    addImportedThings isig ibuiltin
		    return (i, t)

readInterface :: FilePath -> IO (Maybe Interface)
readInterface file = do
    -- Decode the interface file
    (s, close) <- readBinaryFile' file
    do  i <- decode s

        -- Force the entire string, to allow the file to be closed.
        let n = BS.length s
        () <- when (n == n) $ return ()

        -- Close the file
        close

	-- Force the interface to make sure the interface version is looked at
        i `seq` return $ Just i
      -- Catch exceptions and close
      `catch` \e -> close >> handler e
  -- Catch exceptions
  `catch` handler
  where
    handler e = case e of
      ErrorCall _   -> return Nothing
      IOException e -> do
          UTF8.putStrLn $ "IO exception: " ++ show e
          return Nothing   -- work-around for file locking bug
      _		    -> throwIO e

writeInterface :: FilePath -> Interface -> IO ()
writeInterface file i = do
    encodeFile file i
  `catch` \e -> do
    UTF8.putStrLn $ "failed to write interface " ++ file ++ " : " ++ show e
    removeFile file
    return ()

createInterface :: CommandLineOptions -> CallTrace -> [ModuleName] -> VisitedModules ->
		   DecodedModules -> Signature -> BuiltinThings PrimFun ->
                   ModuleName -> FilePath ->
		   IO (Either TCErr (VisitedModules, DecodedModules, Interface, Signature, BuiltinThings PrimFun))
createInterface opts trace path visited decoded isig ibuiltin mname file =
  runTCM $ withImportPath path $ do

    setDecodedModules decoded
    setTrace trace
    setCommandLineOptions opts
    setVisitedModules visited

    reportSLn "import.iface.create" 5  $ "Creating interface for " ++ show mname
    reportSLn "import.iface.create" 10 $ "  visited: " ++ show (Map.keys visited)

    addImportedThings isig ibuiltin

    (pragmas, top) <- liftIO $ parseFile' moduleParser file
    pragmas	   <- concat <$> concreteToAbstract_ pragmas -- identity for top-level pragmas
    topLevel	   <- concreteToAbstract_ (TopLevel top)

    -- Check the module name
    let mname' = scopeName $ head $ scopeStack $ insideScope topLevel
    unless (mname' == mname) $ typeError $ ModuleNameDoesntMatchFileName mname' mname

    setOptionsFromPragmas pragmas

    checkDecls $ topLevelDecls topLevel
    errs <- ifM (optTerminationCheck <$> commandLineOptions)
                (termDecls $ topLevelDecls topLevel)
                (return [])
    mapM_ (\e -> reportSLn "term.warn.no" 1
                 (show (fst e) ++ " does NOT termination check")) errs

    -- Generate Vim file
    whenM (optGenerateVimFile <$> commandLineOptions) $
	withScope_ (insideScope topLevel) $ generateVimFile file

    -- Generate Emacs file
    whenM (optGenerateEmacsFile <$> commandLineOptions) $
      generateEmacsFile file TypeCheckingDone topLevel errs

    -- check that metas have been solved
    ms <- getOpenMetas
    case ms of
	[]  -> return ()
	_   -> do
	    rs <- mapM getMetaRange ms
	    typeError $ UnsolvedMetasInImport $ List.nub rs

    setScope $ outsideScope topLevel

    i        <- buildInterface
    isig     <- getImportedSignature
    vs       <- getVisitedModules
    ds       <- getDecodedModules
    ibuiltin <- gets stImportedBuiltins
    return (vs, ds, i, isig, ibuiltin)

buildInterface :: TCM Interface
buildInterface = do
    reportSLn "import.iface" 5 "Building interface..."
    scope   <- getScope
    sig	    <- getSignature
    builtin <- gets stLocalBuiltins
    ms	    <- getImports
    hsImps  <- getHaskellImports
    let	builtin' = Map.mapWithKey (\x b -> fmap (const x) b) builtin
    reportSLn "import.iface" 7 "  instantiating all meta variables"
    i <- instantiateFull $ Interface
			{ iImportedModules = Set.toList ms
			, iScope	   = head $ scopeStack scope -- TODO!!
			, iSignature	   = sig
			, iBuiltin	   = builtin'
                        , iHaskellImports  = hsImps
			}
    reportSLn "import.iface" 7 "  interface complete"
    return i


-- | Put some of this stuff in a Agda.Utils.File
type Suffix = String

{-| Turn a module name into a file name with the given suffix.
-}
moduleNameToFileName :: C.QName -> Suffix -> FilePath
moduleNameToFileName (C.QName  x) ext = show x ++ ext
moduleNameToFileName (C.Qual m x) ext = show m ++ [slash] ++ moduleNameToFileName x ext

-- | Move somewhere else.
matchFileName :: ModuleName -> FilePath -> Bool
matchFileName mname file = expected `isSuffixOf` given || literate `isSuffixOf` given
  where
    given    = splitPath file
    expected = splitPath $ moduleNameToFileName (mnameToConcrete mname) ".agda"
    literate = splitPath $ moduleNameToFileName (mnameToConcrete mname) ".lagda"

-- | Check that the top-level module name matches the file name.
checkModuleName :: TopLevelInfo -> FilePath -> TCM ()
checkModuleName topLevel file = do
  let mname = scopeName $ head $ scopeStack $ insideScope topLevel
      mod = moduleNameToFileName (mnameToConcrete mname)
  unless (matchFileName mname file) $ typeError $ GenericError $
      "The name of the top level module does not match the file name. " ++
      "The module " ++ show mname ++ " should be defined in either " ++
      mod ".agda" ++ " or " ++ mod ".lagda" ++ ","

-- | True if the first file is newer than the second file. If a file doesn't
-- exist it is considered to be infinitely old.
isNewerThan :: FilePath -> FilePath -> IO Bool
isNewerThan new old = do
    newExist <- doesFileExist new
    oldExist <- doesFileExist old
    if not (newExist && oldExist)
	then return newExist
	else do
	    newT <- getModificationTime new
	    oldT <- getModificationTime old
	    return $ newT >= oldT


