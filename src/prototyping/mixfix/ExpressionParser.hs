------------------------------------------------------------------------
-- Turning graphs into expression parsers
------------------------------------------------------------------------

{-# LANGUAGE FlexibleContexts, GADTs #-}

module ExpressionParser
  ( Token(..)
  , Pos(..)
  , Expr(..)
  , NT
  , expression
  , grammar
  ) where

import Parser
import PrecedenceGraph
import Utilities
import IndexedOrd

import Control.Applicative as A
import qualified Data.List as List
import Data.Set (Set)

-- | Tokens. Placeholders are used to indicate sections. Wildcards
-- indicate things the type checker should fill in automatically
-- (hopefully). Names stand for operator name parts (and possibly
-- other identifiers as well).

data Token = Name String | Placeholder Pos | Wildcard | LParen | RParen
  deriving (Eq, Ord, Show)

-- | Placeholder positions.

data Pos = Beg  -- ^ At the beginning of an operator.
         | Mid  -- ^ In the middle of an operator.
         | End  -- ^ At the end of an operator.
  deriving (Eq, Ord, Show)

-- | Expressions.

data Expr = Fun String
          | App Expr [Expr]
            -- ^ Note that the application of an operator to its
            -- arguments is represented using 'Op', not 'App'.
          | Op String [Maybe Expr]
            -- ^ An application of an operator to /all/ its arguments.
            -- 'Nothing' stands for a placeholder.
          | WildcardE
  deriving (Eq, Ord, Show)

-- | Operator applications.

type Op = (String, [Maybe Expr])

-- | Functions for applying 'Op'erator applications to 'Expr'essions.

appLeft :: Maybe Expr -> Op -> Op
appLeft e (n, es) = ('_' : n, e : es)

appRight :: Op -> Maybe Expr -> Op
appRight (n, es) e = (n ++ "_", es ++ [e])

appBoth :: Maybe Expr -> Op -> Maybe Expr -> Op
appBoth e1 o e2 = appLeft e1 (appRight o e2)

-- | Converts an 'Op'erator application to an 'Expr'ession.

toE :: Op -> Expr
toE (n, es) = Op n es

-- | Nonterminals used by the expression grammar.

data NT r where
  ExprN :: Set Node -> NT Expr
  OpN   :: Set Name -> NT Op
  NodeN :: Node     -> NT Expr
  AtomN ::             NT Expr

instance IndexedEq NT where
  iEq (ExprN ns1) (ExprN ns2) = boolToEq $ ns1 == ns2
  iEq (OpN ns1)   (OpN ns2)   = boolToEq $ ns1 == ns2
  iEq (NodeN n1)  (NodeN n2)  = boolToEq $ n1  == n2
  iEq AtomN       AtomN       = Just Refl
  iEq _           _           = Nothing

instance IndexedOrd NT where
  iCompare (ExprN ns1) (ExprN ns2) = compare ns1 ns2
  iCompare (ExprN _)   _           = LT
  iCompare (OpN _)     (ExprN _)   = GT
  iCompare (OpN ns1)   (OpN ns2)   = compare ns1 ns2
  iCompare (OpN _)     _           = LT
  iCompare (NodeN n1)  (ExprN _)   = GT
  iCompare (NodeN n1)  (OpN _)     = GT
  iCompare (NodeN n1)  (NodeN n2)  = compare n1 n2
  iCompare (NodeN n1)  _           = LT
  iCompare AtomN       (ExprN _)   = GT
  iCompare AtomN       (OpN _)     = GT
  iCompare AtomN       (NodeN _)   = GT
  iCompare AtomN       AtomN       = EQ

-- | Non-terminal for an expression.

expression :: PrecedenceGraph -> NT Expr
expression g = ExprN (nodes g)

-- | A placeholder of the given kind.

placeholder :: NTParser p NT Token => Pos -> p (Maybe Expr)
placeholder p = Nothing <$ sym (Placeholder p)

-- | The expression grammar.

grammar :: NTParser p NT Token =>
           PrecedenceGraph ->
           -- ^ The precedence graph.
           p String ->
           -- ^ Parser for identifiers/function names (not operator
           -- name parts).
           Set Name ->
           -- ^ Closed mixfix operators.
           NT r -> p r

-- Note that parentheses should not be treated here. The top-level
-- parser should take care of let, lambda, parentheses, hidden
-- argument braces, and pattern dots. (And perhaps something else as
-- well.)

-- Note also that an operator which is sectioned in the right way
-- becomes closed.

grammar g identifier closed AtomN =
      Fun <$> identifier
  <|> WildcardE <$ sym Wildcard
  <|> sym LParen *> nonTerm (expression g) <* sym RParen
  <|> toE <$> (      nonTerm (OpN closed)
    <|> appRight <$> nonTerm (OpN prefix) <*> placeholder End
    <|> appLeft  <$> placeholder Beg <*> nonTerm (OpN postfix)
    <|> appBoth  <$> placeholder Beg <*> nonTerm (OpN infx) <*>
                     placeholder End)
  where
  allOps  = allOperators g
  prefix  = allOps ! Prefix
  postfix = allOps ! Postfix
  infx    = allInfix allOps

-- Production for a subset of the expressions. Only the nodes
-- reachable from the given set of nodes are recognised.

grammar _ _ _ (ExprN ns)
   =  nonTerm AtomN
  <|> App <$> nonTerm AtomN <*> many1 (nonTerm AtomN)
  <|> choice (map' (nonTerm . NodeN) ns)

-- Production for operators (just the internal, mixfix parts; not the
-- "outer" arguments).

grammar g _ _ (OpN ops) = choice $ map' op ops
  where
  op nameParts =
    (,) (List.intercalate "_" nameParts) <$>
        (Just <$> nonTerm (expression g) <|> placeholder Mid)
          `between`
        map Name nameParts

-- Production for a graph node.

grammar g _ _ (NodeN n) = choice $
  [ flip (foldr appRight') <$> many1 (internal Prefix) <*> higher
  , foldl appLeft'         <$> higher <*> many1 (internal Postfix)
  , appBoth' <$> higher <*> internal (Infix Non) <*> higher
  , chainl3 higher (flip appBoth' <$> internal (Infix L))
  , chainr3 higher (flip appBoth' <$> internal (Infix R))
  ]
  where
  -- Operators of higher precedence or atoms.
  higher = nonTerm (ExprN (successors g n))

  -- The internal parts of operators of the given fixity (in this
  -- node). Includes certain sections; for instance, a left-sectioned
  -- infix operator becomes a prefix operator.
  internal f =  nonTerm (OpN (ann ! f))
            <|> case f of
                  Prefix  -> appLeft  <$> placeholder Beg <*> infx
                  Postfix -> appRight <$> infx <*> placeholder End
                  Infix _ -> A.empty
    where
    ann  = annotation g n
    infx = nonTerm (OpN (allInfix ann))

  appLeft'  e o     = toE $ appLeft  (Just e) o
  appRight' o e     = toE $ appRight o (Just e)
  appBoth'  e1 o e2 = toE $ appBoth  (Just e1) o (Just e2)