
module Lib.Vec where

open import Lib.Prelude
open import Lib.Nat
open import Lib.Fin

infixr 40 _►_

data Vec (A : Set) : Nat -> Set where
  ε   : Vec A 0
  _►_ : forall {n} -> A -> Vec A n -> Vec A (suc n)

_!_ : forall {A n} -> Vec A n -> Fin n -> A
ε      ! ()
x ► xs ! fzero  = x
x ► xs ! fsuc i = xs ! i

tabulate : forall {A n} -> (Fin n -> A) -> Vec A n
tabulate {n = zero}  f = ε
tabulate {n = suc n} f = f fzero ► tabulate (f ∘ fsuc)

vec : forall {A n} -> A -> Vec A n
vec x = tabulate (\_ -> x)

infixl 30 _<*>_

_<*>_ : forall {A B n} -> Vec (A -> B) n -> Vec A n -> Vec B n
ε      <*> ε      = ε
f ► fs <*> x ► xs = f x ► (fs <*> xs)

map : forall {A B n} -> (A -> B) -> Vec A n -> Vec B n
map f xs = vec f <*> xs

zip : forall {A B C n} -> (A -> B -> C) -> Vec A n -> Vec B n -> Vec C n
zip f xs ys = vec f <*> xs <*> ys
