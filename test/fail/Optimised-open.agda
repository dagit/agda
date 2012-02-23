-- The point of this test is to check that we don't create needlessly
-- large anonymous modules when we open a module application.

{-# OPTIONS -vscope.mod.inst:10 -vtc.section.apply:20 #-}

module Optimised-open where

postulate A : Set

module M₁ (A : Set) where
  postulate
    P : A → Set
    X : Set

-- There is no point in creating a module containing X here.
open M₁ A using (P)

postulate
  a : A
  p : P a

module M₂ where

  -- Or here.
  open M₁ A public using () renaming (P to P′)

  postulate
    p′ : P′ a

open M₂

-- Make sure that we get a type error.
postulate
  x : P P
