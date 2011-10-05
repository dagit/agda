{- An adaptation of Edwin Brady and Kevin Hammond's paper Scrapping your inefficient engine ... -}
{-# OPTIONS --type-in-type #-}
module tests.Cat where

open import Prelude.Bool
open import Prelude.Bot
open import Prelude.IO
open import Prelude.Fin
open import Prelude.Eq
open import Prelude.Nat
open import Prelude.Product
open import Prelude.String
open import Prelude.Unit
open import Prelude.Vec

record Top : Set where
  constructor tt

data Ty : Set where
  TyUnit   : Ty
  TyBool   : Ty
  TyLift   : Set -> Ty
  TyHandle : Nat -> Ty

interpTy : Ty -> Set
interpTy TyUnit       = Unit
interpTy TyBool       = Bool
interpTy (TyLift A)   = A
interpTy (TyHandle n) = Fin n

data Purpose : Set where
  Reading : Purpose
  Writing : Purpose
  
getMode : Purpose -> String
getMode Reading = "r"
getMode Writing = "w"

data FileState : Set where
  Open   : Purpose -> FileState
  Closed : FileState

postulate
  EpicFile : Set



static[_] : {A : Set} → A → A
static[ x ] = x

{-# STATIC static[_] #-}


FileVec : Nat -> Set
FileVec n = Vec FileState n

data FileHandle : FileState -> Set where
  OpenFile   : ∀{p} -> EpicFile -> FileHandle (Open p)
  ClosedFile : FileHandle Closed

data Env : ∀{n} -> FileVec n -> Set where
  Empty  : Env []
  Extend : {n : Nat}{T : FileState}{G : FileVec n} -> (res : FileHandle T) -> Env G -> Env (T :: G)

addEnd : ∀{n T}{G : FileVec n} -> Env G -> FileHandle T -> Env (snoc G T)
addEnd Empty         fh = Extend fh Empty
addEnd (Extend x xs) fh = Extend x (addEnd xs fh)

updateEnv : ∀{n T}{G : FileVec n} -> Env G -> (i : Fin n) -> (fh : FileHandle T) -> Env (G [ i ]= T)
updateEnv (Extend x xs) fz     e = Extend e xs
updateEnv (Extend x xs) (fs n) e = Extend x (updateEnv xs n e)
updateEnv Empty         ()     e

bound : ∀{n : Nat} -> Fin (S n)
bound {Z}   = fz
bound {S n} = fs (bound {n})

_==P_ : Purpose -> Purpose -> Set
Reading ==P Reading = Top
Reading ==P Writing = Bot
Writing ==P Reading = Bot
Writing ==P Writing = Top

OpenH : ∀{n} -> Fin n -> Purpose -> FileVec n -> Set
OpenH fz p (Open p' :: as) = p ==P p'
OpenH fz p (Closed  :: as) = Bot
OpenH (fs i) p ( a  :: as) = OpenH i p as

getFile : ∀{n}{i : Fin n}{p : Purpose}{ts : FileVec n}{ope : OpenH i p ts} -> Env ts -> EpicFile
getFile {Z} {()} env 
getFile {S y} {fz} (Extend (OpenFile y') y0) = y'
getFile {S y} {fz} {ope = ()} (Extend ClosedFile y')
getFile {S y} {fs y'} {ope = ope} (Extend res y0) = getFile {y} {y'} {ope = ope} y0

getPurpose : {n : Nat} -> Fin n -> FileVec n -> Purpose
getPurpose f ts with ts ! f
... | Open p = p
... | Closed = Reading -- Should not happen right?

FilePath : Set
FilePath = String

data File : ∀{n n'}  -> FileVec n -> FileVec n' -> Ty -> Set where
  ACTION  : ∀{a l}{ts : FileVec l}  -> IO (interpTy a) -> File ts ts a
  RETURN  : ∀{a l}{ts : FileVec l}  -> interpTy a -> File ts ts a
  WHILE   : ∀{l}{ts : FileVec l}    -> File ts ts TyBool -> File ts ts TyUnit -> File ts ts TyUnit
  IF      : ∀{a l}{ts : FileVec l}  -> Bool -> File ts ts a -> File ts ts a -> File ts ts a
  BIND    : ∀{a b l l' l''}{ts : FileVec l}{ts' : FileVec l'}{ts'' : FileVec l''}
         -> File ts ts' a -> (interpTy a -> File ts' ts'' b) -> File ts ts'' b
  OPEN    : ∀{l}{ts : FileVec l}  
          -> (p : Purpose) -> (fd : FilePath) -> File ts (snoc ts (Open p)) (TyHandle (S l))
  CLOSE   : ∀ {l}{ts : FileVec l} -> (i : Fin l) -> {p : OpenH i (getPurpose i ts) ts} -> File ts (ts [ i ]= Closed) TyUnit
  GETLINE : ∀ {l}{ts : FileVec l} -> (i : Fin l) -> {p : OpenH i Reading ts} -> File ts ts (TyLift String)
  EOF     : ∀ {l}{ts : FileVec l} -> (i : Fin l) -> {p : OpenH i Reading ts} -> File ts ts TyBool
  PUTLINE : ∀ {l}{ts : FileVec l} -> (i : Fin l) -> (str : String) -> {p : OpenH i Writing ts} -> File ts ts TyUnit

postulate
  while  : IO Bool -> IO Unit -> IO Unit
  fopen  : FilePath -> String -> IO EpicFile
  fclose : EpicFile -> IO Unit
  fread  : EpicFile -> IO String
  feof   : EpicFile -> IO Bool
  fwrite : EpicFile -> String -> IO Unit 

{-# COMPILED_EPIC while (add : Any, body : Any, u : Unit) -> Any = %while (add(u), body(u)) #-}
{-# COMPILED_EPIC fopen (fp : Any, mode : Any, u : Unit) -> Ptr = foreign Ptr "fopen" (mkString(fp) : String, mkString(mode) : String) #-}
{-# COMPILED_EPIC fclose (file : Ptr, u : Unit) -> Unit = foreign Int "fclose" (file : Ptr); unit #-}
{-# COMPILED_EPIC fread (file : Ptr, u : Unit) -> Any = frString(foreign String "freadStrChunk" (file : Ptr)) #-}
{-# COMPILED_EPIC feof (file : Ptr, u : Unit) -> Bool = foreign Int "feof" (file : Ptr) #-}
{-# COMPILED_EPIC fwrite (file : Ptr, str : Any, u : Unit) -> Unit =  foreign Unit "fputs" (mkString(str) : String, file : Ptr) #-}

fmap : {A B : Set} -> (A -> B) -> IO A -> IO B
fmap f io = 
  x <- io ,
  return (f x)

data MIO (A : Set) : Set where
  Return : A -> MIO A
  ABind  : {B : Set} -> IO B -> (B -> MIO A) -> MIO A
  -- While  : MIO Bool -> MIO Unit -> MIO Unit

MBind : {A B : Set} -> MIO A -> (A -> MIO B) -> MIO B
MBind (Return x) f = f x
MBind (ABind io k) f = ABind io (λ x -> MBind (k x) f)
-- MBind (While b u) f  = 

mmap : {A B : Set} -> (A -> B) -> MIO A -> MIO B
mmap f mio = MBind mio (λ x -> Return (f x))

runMIO : {A : Set} -> MIO A -> IO A
runMIO (Return x) = return x
runMIO (ABind io f) = 
   x <- io ,
   runMIO (f x)

interp : ∀{n n' T}{ts : FileVec n}{ts' : FileVec n'} -> Env ts -> File ts ts' T -> MIO (Env ts' × interpTy T)
interp env (ACTION io) = ABind io (λ x -> Return (env , x))
interp env (RETURN val) = Return (env , val)
interp env (WHILE add body) =
    ABind (while (runMIO (mmap snd (interp env add))) (runMIO (mmap snd (interp env body)))) (λ _ ->
    Return (env , unit))
interp env (IF b t f) = if b then interp env t else interp env f
interp env (BIND code k) =
    MBind (interp env code) (λ v ->
    interp (fst v) (k (snd v)))
interp env (OPEN p fpath) =
    ABind (fopen fpath (getMode p)) (λ fh ->
    Return (addEnd env (OpenFile fh), bound))
interp env (CLOSE i {p = p}) = 
    ABind (fclose (getFile {_} {i} {ope = p} env)) (\ _ ->
    Return (updateEnv env i ClosedFile , unit))
interp env (GETLINE i {p = p}) = 
    ABind (fread (getFile {_} {i} {ope = p} env)) (λ x -> Return (env , x))
interp env (EOF i {p = p}) =
    
    ABind (feof (getFile {_} {i} {ope = p} env)) (\ e ->
    Return (env , e))
interp env (PUTLINE i str {p = p}) =
      ABind (fwrite (getFile {i = i} {ope = p} env) str) (λ _ -> 
      ABind (fwrite (getFile {i = i} {ope = p} env) "\n") (λ x ->
      Return (env , unit)))

allClosed : (n : Nat) -> FileVec n
allClosed Z     = []
allClosed (S n) = Closed :: allClosed n

syntax BIND e (\ x -> f) = x := e % f
infixl 0 BIND

_%%_ : ∀{a b l l' l''}{ts : FileVec l}{ts' : FileVec l'}{ts'' : FileVec l''}
         -> File ts ts' a -> File ts' ts'' b -> File ts ts'' b
m %% k = BIND m (λ _ -> k)
infixr 0 _%%_

{-
cat : File [] (Closed :: []) TyUnit
cat = (
    fz := OPEN Reading "tests/Cat.out" %
    WHILE (b := EOF fz % RETURN (not b)) ( 
        str := GETLINE fz %
        ACTION (putStrLn str)
    ) %%
    CLOSE fz
 )


cont : Fin 1 -> File (Open Reading :: []) (Closed :: []) TyUnit
cont (fs ())
cont fz =  BIND (WHILE (BIND (EOF fz) (\b -> RETURN (not b)))
                       (BIND (GETLINE fz)
                             (\str -> ACTION (putStrLn str))
                       )
                )
                (λ x → CLOSE fz)

cat : File [] (Closed :: []) TyUnit
cat = BIND (OPEN Reading "hej")
            cont

-}

cont : Fin 1 -> File (Open Reading :: []) (Closed :: []) TyUnit
cont (fs ())
cont fz =
  WHILE ( b := EOF fz % RETURN (not b)) (
      str := GETLINE fz %
      ACTION (putStr str)
  ) %%
  CLOSE fz

cat : File [] (Closed :: []) TyUnit
cat = BIND (OPEN Reading "tests/Cat.out") cont

copy : File [] (Closed :: Closed :: []) TyUnit
copy = 
  BIND (OPEN Reading "copy/input")  (λ _ → 
  BIND (OPEN Writing "copy/output") (λ _ → 
  BIND (WHILE (BIND (EOF fz) (λ b → RETURN (not b))) 
       (BIND (GETLINE fz) (λ str → PUTLINE (fs fz) str))) (λ _ → 
  BIND (CLOSE fz) (λ _ → 
  CLOSE (fs fz)))))

runProg : {n : Nat} -> File [] (allClosed n) TyUnit -> IO Unit
runProg p = runMIO (mmap snd (interp Empty p))

{-# STATIC runProg #-}

main : IO Unit
main = runProg cat -- static[ runProg cat ]
-- main = runProg cat