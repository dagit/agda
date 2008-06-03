
module Agda.TypeChecking.Monad.Closure where

import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Monad.Env
import Agda.TypeChecking.Monad.State
import Agda.TypeChecking.Monad.Signature
import Agda.TypeChecking.Monad.Trace

enterClosure :: MonadTCM tcm => Closure a -> (a -> tcm b) -> tcm b
enterClosure (Closure sig env scope trace x) k =
    withScope_ scope
    $ withSignature sig
    $ withEnv env
    $ withTrace trace
    $ k x
    
