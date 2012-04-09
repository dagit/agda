{-# LANGUAGE CPP, TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses, Rank2Types #-}
{-# OPTIONS -fno-cse #-}

module Agda.Interaction.GhciTop
  ( module Agda.Interaction.GhciTop
  , module Agda.Interaction.InteractionTop
  , module Agda.TypeChecker
  , module Agda.TypeChecking.MetaVars
  , module Agda.TypeChecking.Reduce
  , module Agda.TypeChecking.Errors

  , module Agda.Syntax.Position
  , module Agda.Syntax.Parser
  , module Agda.Syntax.Scope.Base
  , module Agda.Syntax.Scope.Monad
  , module Agda.Syntax.Translation.ConcreteToAbstract
  , module Agda.Syntax.Translation.AbstractToConcrete
  , module Agda.Syntax.Translation.InternalToAbstract
  , module Agda.Syntax.Abstract.Name

  , module Agda.Interaction.Exceptions

  , mkAbsolute
  )
  where

import qualified System.IO as IO
import System.IO.Unsafe
import Data.IORef
import Control.Applicative hiding (empty)

import Agda.Utils.Pretty
import Agda.Utils.FileName

import Control.Monad.State
import System.Exit

import Agda.TypeChecker
import Agda.TypeChecking.Monad as TM hiding (initState, setCommandLineOptions)
import Agda.TypeChecking.MetaVars
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Errors

import Agda.Syntax.Position
import Agda.Syntax.Parser
import Agda.Syntax.Concrete.Pretty ()
import Agda.Syntax.Abstract as SA
import Agda.Syntax.Scope.Base
import Agda.Syntax.Scope.Monad hiding (bindName, withCurrentModule)
import Agda.Syntax.Translation.ConcreteToAbstract
import Agda.Syntax.Translation.AbstractToConcrete hiding (withScope)
import Agda.Syntax.Translation.InternalToAbstract
import Agda.Syntax.Abstract.Name

import Agda.Interaction.GhcTop
import Agda.Interaction.InteractionTop
import qualified Agda.Interaction.EmacsCommand as Emacs
import Agda.Interaction.Exceptions
import Agda.Interaction.Response

#include "../undefined.h"
import Agda.Utils.Impossible

------------------------------------------

-- | The global state is needed only for the GHCi backend.

{-# NOINLINE theState #-}
theState :: IORef InteractionState
theState = unsafePerformIO $ newIORef $ emacsOutput initState

-- | Redirect the output to stdout in elisp format
--   suitable for the interactive emacs frontend.

emacsOutput :: InteractionState -> InteractionState
emacsOutput (InteractionState st cs) = InteractionState (st { stInteractionOutputCallback = emacsFormat }) cs

-- | Convert the response (to an interactive command)
--   to elisp expressions suitable for the interactive emacs frontend
--   and print it to stdout.

emacsFormat :: Response -> IO ()
emacsFormat = Emacs.putResponse <=< lispifyResponse


-- | Run a TCM computation in the current state. Should only
--   be used for debugging.

ioTCM_ :: TCM a -> IO a
ioTCM_ m = do
  InteractionState tcs cs <- readIORef theState
  result <- runTCM $ do
    put tcs
    x <- withEnv (initEnv { envEmacs = True }) m
    tcs <- get
    return (x, tcs)
  case result of
    Right (x, tcs) -> do
      writeIORef theState $ InteractionState tcs cs
      return x
    Left err -> do
      Right doc <- runTCM $ prettyTCM err
      putStrLn $ render doc
      return __IMPOSSIBLE__
{-
  Right (x, s) <- runTCM $ do
    put $ theTCState tcs
    x <- withEnv initEnv m
    s <- get
    return (x, s)
  writeIORef theState $ tcs { theTCState = s }
  return x
-}

-- | Runs a 'TCM' computation. All calls from the Emacs mode should be
--   wrapped in this function.

ioTCM :: FilePath
         -- ^ The current file. If this file does not match
         -- 'theCurrentFile, and the 'Interaction' is not
         -- \"independent\", then an error is raised.
      -> Bool
         -- ^ Should syntax highlighting information be produced? In
         -- that case this function will generate an Emacs command
         -- which interprets this information.
      -> Interaction
      -> IO ()
ioTCM current highlighting cmd = do
#if MIN_VERSION_base(4,2,0)
  -- Ensure that UTF-8 is used for communication with the Emacs mode.
  IO.hSetEncoding IO.stdout IO.utf8
#endif

  -- Read the state.
  state <- readIORef theState

  response <- ioTCMState current highlighting cmd $ emacsOutput state

  -- Write the state or halt with an error.
  case response of
    Just state -> writeIORef theState state
    Nothing ->    exitWith (ExitFailure 1)


-- Helpers for testing ----------------------------------------------------

getCurrentFile :: IO FilePath
getCurrentFile = do
  mf <- (theCurrentFile . theCommandState) <$> readIORef theState
  case mf of
    Nothing     -> error "command: No file loaded!"
    Just (f, _) -> return (filePath f)

top_command' :: FilePath -> Interaction -> IO ()
top_command' f cmd = ioTCM f False cmd

goal_command :: InteractionId -> GoalCommand -> String -> IO ()
goal_command i cmd s = do
  f <- getCurrentFile
  -- TODO: Test with other ranges as well.
  ioTCM f False $ cmd i noRange s
