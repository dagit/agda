{-# LANGUAGE DeriveDataTypeable
  #-}
module Agda.Compiler.JS.Syntax where

import Data.Generics ( Data, Typeable )
import Data.Map ( Map, fold )
import Data.Set ( Set, empty, singleton, union )

import Agda.Syntax.Common ( Nat )

-- An untyped lambda calculus with records,
-- and a special self-binder for recursive declarations

data Exp =
  Self |
  Local LocalId |
  Global GlobalId |
  Undefined |
  String String |
  Char Char |
  Integer Integer |
  Double Double |
  Lambda Nat Exp |
  Object (Map MemberId Exp) |
  Apply Exp [Exp] |
  Lookup Exp MemberId |
  If Exp Exp Exp |
  BinOp Exp String Exp |
  PreOp String Exp |
  Const String
  deriving (Typeable, Data, Show)

-- Local identifiers are named by De Bruijn indices.
-- Global identifiers are named by string lists.
-- Object members are named by strings.

newtype LocalId = LocalId Nat
  deriving (Typeable, Data, Eq, Ord, Show)

newtype GlobalId = GlobalId [String]
  deriving (Typeable, Data, Eq, Ord, Show)

newtype MemberId = MemberId String
  deriving (Typeable, Data, Eq, Ord, Show)

-- The top-level compilation unit is a module, which names
-- the GId of its exports, and the GIds of its imports.

data Module = Module { modName :: GlobalId, imports :: [GlobalId], export :: Exp }
  deriving (Typeable, Data, Show)

-- Note that modules are allowed to be recursive, via the Self expression,
-- which is bound to the exported module.

globals :: Exp -> Set GlobalId
globals (Global i) = singleton i
globals (Lambda n e) = globals e
globals (Object o) = fold (union . globals) empty o
globals (Apply e es) = foldr (union . globals) (globals e) es
globals (Lookup e l) = globals e
globals (If e f g) = globals e `union` globals f `union` globals g
globals (BinOp e op f) = globals e `union` globals f
globals (PreOp op e) = globals e
globals _ = empty
