{-# LANGUAGE MultiParamTypeClasses, FlexibleContexts, FlexibleInstances,
             RankNTypes, GADTs, TypeFamilies, ScopedTypeVariables #-}
{-# OPTIONS -Wall #-}

module Language.Hakaru.Disintegrate where

import Prelude hiding (mapM, lookup, (!!), Real)
import Data.Either (partitionEithers)
import Data.Maybe (isJust, isNothing, fromMaybe)
import Data.Monoid (Monoid (mempty, mappend, mconcat))
import Data.Graph (graphFromEdges, topSort)
import Data.Ratio (Ratio, numerator, denominator)
import Data.List (tails)
import qualified Data.Set as S
import Control.Applicative (Applicative(pure, (<*>)), Const(Const),
        WrappedMonad(WrapMonad, unwrapMonad))
import Control.Monad.Trans.RWS (runRWS, get, put, tell)
import Control.Monad (mapM, liftM2, zipWithM_)
import Control.Monad.Trans.Cont (Cont, cont, runCont)
import Language.Hakaru.Util.Pretty (Pretty (pretty))
import Text.PrettyPrint (Doc, text, char, int, comma, colon, semi, brackets,
        parens, (<>), (<+>), ($$), nest, fsep, sep, punctuate, render)
import Language.Hakaru.Syntax (Real, Prob, Measure, Type(..), TypeOf(..),
        typeOf, typeOf1, typeOf2, EqType(..), eqType, OrdType(..), ordType,
        Order(..), Base(..), Mochastic(..), liftM, snd_)

------- Tracing and pretty-printing

--import Debug.Trace (traceShow)
traceShow :: (Show a) => a -> b -> b
traceShow _ = id

prettyPair :: Doc -> Doc -> Doc
prettyPair a b = parens (sep (punctuate comma [a, b]))

prettyParen :: Bool -> Doc -> Doc
prettyParen True  = parens
prettyParen False = id

prettyFun :: Bool -> String -> Doc -> Doc
prettyFun p f doc = prettyParen p (text f <+> nest (length f + 1) doc)

prettyOp :: Bool -> String -> Doc -> Doc -> Doc
prettyOp p op doc1 doc2 = prettyParen p (sep [doc1, text op <+> doc2])

showRatio :: (Show a, Integral a) => Int -> Ratio a -> ShowS
showRatio p r | num < 0    = showParen (p > 6)
                           $ showChar '-' . showRatio 7 (-r)
              | denom == 1 = showsPrec p num
              | otherwise  = showParen (p > 7)
                           $ showsPrec 8 num . showChar '/' . showsPrec 8 denom
  where denom = denominator r
        num   = numerator r

------- Lift common type-classes from kind * to kind "Type -> *"
-- Variables are typed in environments, and locations are typed in heaps.

jmEq :: (Type t1, Type t2, Eq' a) => a t1 -> a t2 -> Maybe (EqType t1 t2)
jmEq x y = do Refl <- eqType (typeOf x) (typeOf y)
              if eq' x y then Just Refl else Nothing

class Eq' a where
  eq' :: a t -> a t -> Bool

eq'List :: (Eq' a) => [a t] -> [a t] -> Bool
eq'List []     []     = True
eq'List (x:xs) (y:ys) = eq' x y && eq'List xs ys
eq'List []     (_:_)  = False
eq'List (_:_)  []     = False

class (Eq' a) => Ord' a where
  ord' :: a t -> a t -> Ordering

ord'List :: (Ord' a) => [a t] -> [a t] -> Ordering
ord'List []     []     = EQ
ord'List (x:xs) (y:ys) = ord' x y `mappend` ord'List xs ys
ord'List []     (_:_)  = LT
ord'List (_:_)  []     = GT

class Show' a where
  show'       :: Int -> a t -> ShowS
  show'   p a = showString (render (pretty' p a))
  pretty'     :: Int -> a t -> Doc
  pretty' p a = text (show' p a "")

class Functor' f where
  fmap' :: (forall t. a t -> b t) -> f a t' -> f b t'

class Foldable' f where
  foldMap' :: (Type t', Monoid m) => (forall t. (Type t) => a t -> m) ->
              f a t' -> m

class (Functor' f, Foldable' f) => Traversable' f where
  traverse' :: (Type t', Applicative m) =>
               (forall t. (Type t) => a t -> m (b t)) -> f a t' -> m (f b t')
  mapM'     :: (Type t', Monad m) =>
               (forall t. (Type t) => a t -> m (b t)) -> f a t' -> m (f b t')
  mapM' f = unwrapMonad . traverse' (WrapMonad . f)

instance Show' TypeOf where
  pretty' p x@Meas = prettyFun (p > 10) "Measure" (pretty' 11 (typeOf2 x))
  pretty' _ x@Prod = prettyPair (pretty' 0 (typeOf1 x)) (pretty' 0 (typeOf2 x))
  pretty' p x@Sum  = prettyFun (p > 10) "Either"
                   $ sep [ pretty' 11 (typeOf1 x), pretty' 11 (typeOf2 x) ]
  pretty' p x@Fun  = prettyParen (p > 0)
                   $ sep [ pretty' 1 (typeOf1 x) <+> text "->",
                           pretty' 0 (typeOf2 x) ]
  pretty' _   One  = text "()"
  pretty' _   Real = text "Real"
  pretty' _   Prob = text "Prob"

------- Trees, which form the left-hand-sides of bindings

data Tree a t where
  Branch :: Tree a t1 -> Tree a t2 -> Tree a (t1, t2)
  UnaryL :: Tree a t1 -> Tree a (Either t1 t2)
  UnaryR :: Tree a t2 -> Tree a (Either t1 t2)
  Nil    :: Tree a ()
  Leaf   :: a t -> Tree a t

instance (Eq' a) => Eq' (Tree a) where
  eq' (Branch a1 b1) (Branch a2 b2) = eq' a1 a2 && eq' b1 b2
  eq' (UnaryL a)     (UnaryL b)     = eq' a b
  eq' (UnaryR a)     (UnaryR b)     = eq' a b
  eq' Nil            Nil            = True
  eq' (Leaf a)       (Leaf b)       = eq' a b
  eq' _              _              = False

instance (Ord' a) => Ord' (Tree a) where
  ord' (Branch a1 b1) (Branch a2 b2) = ord' a1 a2 `mappend` ord' b1 b2
  ord' (Branch _ _)   (Leaf _)       = LT
  ord' (Leaf _)       (Branch _ _)   = GT
  ord' (UnaryL a)     (UnaryL b)     = ord' a b
  ord' (UnaryR a)     (UnaryR b)     = ord' a b
  ord' (UnaryL _)     (UnaryR _)     = LT
  ord' (UnaryR _)     (UnaryL _)     = GT
  ord' (UnaryL _)     (Leaf _)       = LT
  ord' (UnaryR _)     (Leaf _)       = LT
  ord' (Leaf _)       (UnaryL _)     = GT
  ord' (Leaf _)       (UnaryR _)     = GT
  ord' Nil            Nil            = EQ
  ord' Nil            (Leaf _)       = LT
  ord' (Leaf _)       Nil            = GT
  ord' (Leaf a)       (Leaf b)       = ord' a b

instance (Show' a) => Show' (Tree a) where
  pretty' _ (Branch a b) = prettyPair (pretty' 0 a) (pretty' 0 b)
  pretty' p (UnaryL a)   = prettyFun (p > 10) "L" (pretty' 11 a)
  pretty' p (UnaryR b)   = prettyFun (p > 10) "R" (pretty' 11 b)
  pretty' p (Leaf a)     = pretty' p a
  pretty' _ Nil          = text "()"

instance Functor' Tree where
  fmap' f (Branch a b) = fmap' f a `Branch` fmap' f b
  fmap' f (UnaryL a)   = UnaryL (fmap' f a)
  fmap' f (UnaryR b)   = UnaryR (fmap' f b)
  fmap' _ Nil          = Nil
  fmap' f (Leaf a)     = Leaf (f a)

instance Foldable' Tree where
  foldMap' f x@(Branch a b) = case typeOf x of
                              Prod -> foldMap' f a `mappend` foldMap' f b
  foldMap' f x@(UnaryL a)   = case typeOf x of Sum -> foldMap' f a
  foldMap' f x@(UnaryR b)   = case typeOf x of Sum -> foldMap' f b
  foldMap' _   Nil          = mempty
  foldMap' f   (Leaf a)     = f a

instance Traversable' Tree where
  traverse' f x@(Branch a b) = case typeOf x of
                               Prod -> fmap Branch (traverse' f a)
                                                <*> traverse' f b
  traverse' f x@(UnaryL a)   = case typeOf x of
                               Sum -> fmap UnaryL (traverse' f a)
  traverse' f x@(UnaryR b)   = case typeOf x of
                               Sum -> fmap UnaryR (traverse' f b)
  traverse' _   Nil          = pure Nil
  traverse' f   (Leaf a)     = fmap Leaf (f a)

------- Selectors, which name a part of an algebraic data type to evaluate
-- For example, evaluating at Root is evaluating to whnf.
-- To take another example, disintegrating at Root is calculating density.

data Selector to t where
  Fst  :: Selector to t -> Selector to (t, t')
  Snd  :: Selector to t -> Selector to (t', t)
  Unl  :: Selector to t -> Selector to (Either t t')
  Unr  :: Selector to t -> Selector to (Either t' t)
  Root :: Selector to to

instance Show' (Selector to) where
  pretty' p (Fst s) = prettyFun (p > 10) "Fst" (pretty' 11 s)
  pretty' p (Snd s) = prettyFun (p > 10) "Snd" (pretty' 11 s)
  pretty' p (Unl s) = prettyFun (p > 10) "Unl" (pretty' 11 s)
  pretty' p (Unr s) = prettyFun (p > 10) "Unr" (pretty' 11 s)
  pretty' _ Root    = text "Root"

locate :: (Eq' a, Show' a, Type to, Type t) =>
          a to -> Tree a t -> Maybe (Selector to t)
locate x y@(Branch a b) =
  case typeOf y of
  Prod -> case (locate x a, locate x b) of
          (Just _ , Just _ ) -> error ("Duplicate " ++ show' 0 x "")
          (Just s , Nothing) -> Just (Fst s)
          (Nothing, Just s ) -> Just (Snd s)
          (Nothing, Nothing) -> Nothing
locate x y@(UnaryL a) = case typeOf y of Sum -> fmap Unl (locate x a)
locate x y@(UnaryR a) = case typeOf y of Sum -> fmap Unr (locate x a)
locate _   Nil        = Nothing
locate x   (Leaf a)   = do Refl <- jmEq x a
                           Just Root

compose :: Selector t2 t3 -> Selector t1 t2 -> Selector t1 t3
compose (Fst s1) s2 = Fst (compose s1 s2)
compose (Snd s1) s2 = Snd (compose s1 s2)
compose (Unl s1) s2 = Unl (compose s1 s2)
compose (Unr s1) s2 = Unr (compose s1 s2)
compose Root     s2 = s2

------- Names (variables in the input) and locations (variables in the output)

type Name = Const String
type Loc  = Const Int

instance (Eq  a) => Eq'  (Const a) where eq'  (Const x) (Const y) = x == y
instance (Ord a) => Ord' (Const a) where ord' (Const x) (Const y) = compare x y

instance Show' Name where pretty' _ (Const n) = text n
instance Show' Loc  where pretty' _ (Const l) = char '_' <> int l

-- An empty type constructor to express the invariant that values (expressions
-- produced by evaluation) never use Bind to bind any variables (locations):

data Void t

exFalso :: Void t -> a
exFalso _ = error "quodlibet"

instance Eq'   Void where eq'       = exFalso
instance Ord'  Void where ord'      = exFalso
instance Show' Void where show'   _ = exFalso
                          pretty' _ = exFalso

------- An entry in an environment or heap, containing run-time type information
-- An existential quantifier over a product, similar to Coq's "exists2".

data Binding a b where Binding :: (Type t) => a t -> b t -> Binding a b

instance (Eq' a, Eq' b) => Eq (Binding a b) where
  Binding a b == Binding a' b' = case jmEq a a' of Just Refl -> eq' b b'
                                                   Nothing   -> False

instance (Ord' a, Ord' b) => Ord (Binding a b) where
  Binding a b `compare` Binding a' b' =
    case ordType (typeOf a) (typeOf a') of
      LT' -> LT
      GT' -> GT
      EQ' -> ord' a a' `mappend` ord' b b'

instance (Show' a, Show' b) => Show (Binding a b) where
  showsPrec p = showsPrec p . pretty

instance (Show' a, Show' b) => Pretty (Binding a b) where
  pretty (Binding a b) =
    prettyPair (pretty' 0 a <> colon <+> pretty' 1 (typeOf a))
               (pretty' 0 b)

------- Environments map names (input variables) to locations (output variables)

type Env = [Binding Name Loc]

emptyEnv :: Env
emptyEnv = []

lookup :: (Type t, Eq' a) => [Binding a b] -> a t -> Maybe (b t)
lookup [] _ = Nothing
lookup (Binding a b : bindings) a' = case jmEq a a' of
  Just Refl -> Just b
  Nothing   -> lookup bindings a'

(!!) :: (Type t, Eq' a, Show' a) => [Binding a b] -> a t -> b t
env !! n = fromMaybe (error ("Unbound name " ++ show' 0 n "")) (lookup env n)

unique :: (Eq' a) => [Binding a b] -> Bool
unique env = and [ isNothing (jmEq n1 n2)
                 | Binding n1 _ : bs <- tails env, Binding n2 _ <- bs ]

------- Mochastic expressions!
-- Boilerplate galore.

data Expr b u t where -- b = bound variables; u = used variables
  Lebesgue ::                                   Expr b u (Measure Real)
  LitReal  :: Rational ->                       Expr b u Real
  Pi       ::                                   Expr b u Real
  Var      :: u t ->                            Expr b u t
  Exp      :: Expr b u Real ->                  Expr b u Real
  Log      :: Expr b u Real ->                  Expr b u Real
  Neg      :: Expr b u Real ->                  Expr b u Real
  Inv      :: Expr b u Real ->                  Expr b u Real
  Add      :: Expr b u Real -> Expr b u Real -> Expr b u Real
  Mul      :: Expr b u Real -> Expr b u Real -> Expr b u Real
  Less     :: Expr b u Real -> Expr b u Real -> Expr b u (Either () ())
  Weight   :: Expr b u Real ->                  Expr b u (Measure ())
  Choice   :: [Expr b u (Measure t)] ->         Expr b u (Measure t)
  Bind     :: (Type t) => Tree b t -> Expr b u (Measure t) ->
                       Expr b u (Measure t') -> Expr b u (Measure t')
  Dirac    :: Expr b u t ->                     Expr b u (Measure t)
  Pair     :: Expr b u t -> Expr b u t' ->      Expr b u (t, t')
  Inl      :: Expr b u t ->                     Expr b u (Either t t')
  Inr      :: Expr b u t ->                     Expr b u (Either t' t)
  Unit     ::                                   Expr b u ()
  -- The Closure constructor below is for internal use
  -- and should not appear in the final output.
  Closure  :: Expr Name Name (Measure t) -> [Binding Name u] ->
                                                 Expr b u (Measure t)

instance (Eq' b, Eq' u) => Eq' (Expr b u) where
  eq' Lebesgue     Lebesgue       = True
  eq' (LitReal x)  (LitReal x')   = x == x'
  eq' Pi           Pi             = True
  eq' (Var u)      (Var u')       = eq' u u'
  eq' (Exp e)      (Exp e')       = eq' e e'
  eq' (Log e)      (Log e')       = eq' e e'
  eq' (Neg e)      (Neg e')       = eq' e e'
  eq' (Inv e)      (Inv e')       = eq' e e'
  eq' (Add  e1 e2) (Add  e1' e2') = eq' e1 e1' && eq' e2 e2'
  eq' (Mul  e1 e2) (Mul  e1' e2') = eq' e1 e1' && eq' e2 e2'
  eq' (Less e1 e2) (Less e1' e2') = eq' e1 e1' && eq' e2 e2'
  eq' (Weight e)   (Weight e')    = eq' e e'
  eq' (Choice es)  (Choice es')   = eq'List es es'
  eq' (Bind lhs rhs body) (Bind lhs' rhs' body') =
    case eqType (typeOf lhs) (typeOf lhs') of
      Just Refl -> eq' lhs lhs' && eq' rhs rhs' && eq' body body'
      Nothing -> False
  eq' (Dirac e1)   (Dirac e1')    = eq' e1 e1'
  eq' (Pair e1 e2) (Pair e1' e2') = eq' e1 e1' && eq' e2 e2'
  eq' (Inl e1)     (Inl e1')      = eq' e1 e1'
  eq' (Inr e1)     (Inr e1')      = eq' e1 e1'
  eq' Unit         Unit           = True
  eq' (Closure e env) (Closure e' env') = eq' e e' && env == env'
  eq' _ _ = False

instance (Ord' b, Ord' u, Show' b, Show' u) => Ord' (Expr b u) where
  ord' Lebesgue     Lebesgue       = EQ
  ord' (LitReal x)  (LitReal x')   = compare x x'
  ord' Pi           Pi             = EQ
  ord' (Var u)      (Var u')       = ord' u u'
  ord' (Exp e)      (Exp e')       = ord' e e'
  ord' (Log e)      (Log e')       = ord' e e'
  ord' (Neg e)      (Neg e')       = ord' e e'
  ord' (Inv e)      (Inv e')       = ord' e e'
  ord' (Add  e1 e2) (Add  e1' e2') = ord' e1 e1' `mappend` ord' e2 e2'
  ord' (Mul  e1 e2) (Mul  e1' e2') = ord' e1 e1' `mappend` ord' e2 e2'
  ord' (Less e1 e2) (Less e1' e2') = ord' e1 e1' `mappend` ord' e2 e2'
  ord' (Weight e)   (Weight e')    = ord' e e'
  ord' (Choice es)  (Choice es')   = ord'List es es'
  ord' (Bind lhs rhs body) (Bind lhs' rhs' body') =
    case ordType (typeOf lhs) (typeOf lhs') of
      LT' -> LT
      GT' -> GT
      EQ' -> ord' lhs lhs' `mappend` ord' rhs rhs' `mappend` ord' body body'
  ord' (Dirac e1)   (Dirac e1')    = ord' e1 e1'
  ord' (Pair e1 e2) (Pair e1' e2') = ord' e1 e1' `mappend` ord' e2 e2'
  ord' (Inl e1)     (Inl e1')      = ord' e1 e1'
  ord' (Inr e1)     (Inr e1')      = ord' e1 e1'
  ord' Unit         Unit           = EQ
  ord' (Closure e env) (Closure e' env') = ord' e e' `mappend` compare env env'

  -- TODO: generate the following and more, automatically from Expr definition
  ord' (Var _)     (Log _)     = LT
  ord' (Log _)     (Var _)     = GT
  ord' (Var _)     (Add _ _)   = LT
  ord' (Add _ _)   (Var _)     = GT
  ord' (LitReal _) (Add _ _)   = LT
  ord' (Add _ _)   (LitReal _) = GT
  ord' (LitReal _) (Log _)     = LT
  ord' (Log _)     (LitReal _) = GT
  ord' (LitReal _) (Var _)     = LT
  ord' (Var _)     (LitReal _) = GT
  ord' Pi          (Add _ _)   = LT
  ord' (Add _ _)   Pi          = GT
  ord' Pi          (Log _)     = LT
  ord' (Log _)     Pi          = GT
  ord' Pi          (Var _)     = LT
  ord' (Var _)     Pi          = GT
  ord' e1 e2 = error (show (sep
    [ text "Unimplemented (LT or GT) comparison between",
      pretty' 0 e1, text "and", pretty' 0 e2 ]))

instance (Show' b, Show' u) => Show' (Expr b u) where
  pretty' _ Lebesgue           = text "Lebesgue"
  pretty' p (LitReal x)        = text (showRatio p x "")
  pretty' _ Pi                 = text "Pi"
  pretty' p (Var u)            = pretty' p u
  pretty' p (Exp e)            = prettyFun (p > 10) "Exp" (pretty' 11 e)
  pretty' p (Log e)            = prettyFun (p > 10) "Log" (pretty' 11 e)
  pretty' p (Neg e)            = prettyFun (p > 10) "Neg" (pretty' 11 e)
  pretty' p (Inv e)            = prettyFun (p > 10) "Inv" (pretty' 11 e)
  pretty' p (Add  e1 (Neg e2)) = prettyOp (p > 6) "-" (pretty' 6 e1)
                                                      (pretty' 7 e2)
  pretty' p (Add  e1      e2 ) = prettyOp (p > 6) "+" (pretty' 6 e1)
                                                      (pretty' 7 e2)
  pretty' p (Mul  e1 (Inv e2)) = prettyOp (p > 7) "/" (pretty' 7 e1)
                                                      (pretty' 8 e2)
  pretty' p (Mul  e1      e2 ) = prettyOp (p > 7) "*" (pretty' 7 e1)
                                                      (pretty' 8 e2)
  pretty' p (Less e1      e2 ) = prettyOp (p > 4) "<" (pretty' 5 e1)
                                                      (pretty' 5 e2)
  pretty' p (Weight e)  = prettyFun (p > 10) "Weight" (pretty' 11 e)
  pretty' _ (Choice es) =
    brackets (nest 1 (fsep (punctuate comma (map (pretty' 0) es))))
  pretty' p e@(Bind _ _ _) = prettyParen (p > 10) (sep (loop e))
    where loop (Bind lhs rhs body) = pretty' 0 lhs <+> text "<-" <+>
                                     pretty' 0 rhs <> semi
                                   : loop body
          loop body = [pretty' 0 body]
  pretty' p (Dirac e)       = prettyFun (p > 10) "Dirac" (pretty' 11 e)
  pretty' _ (Pair e1 e2)    = prettyPair (pretty' 0 e1) (pretty' 0 e2)
  pretty' p (Inl e)         = prettyFun (p > 10) "L" (pretty' p e)
  pretty' p (Inr e)         = prettyFun (p > 10) "R" (pretty' p e)
  pretty' _ Unit            = text "()"
  pretty' p (Closure e env) = prettyParen (p > 0)
                                (sep [pretty' 0 e, text "@" <+> pretty env])

bimap' :: (Type t') =>
          (forall t. a t -> b t) ->
          (forall t. (Type t) => c t -> d t) ->
          (forall t. (Type t) => Expr Name Name (Measure t) ->
                     [Binding Name d] -> Expr b d (Measure t)) ->
          Expr a c t' -> Expr b d t'
bimap' _ _ _ Lebesgue       = Lebesgue
bimap' _ _ _ (LitReal x)    = LitReal x
bimap' _ _ _ Pi             = Pi
bimap' _ g _ (Var    u)     = Var    (g u)
bimap' f g h (Exp    e)     = Exp    (bimap' f g h e)
bimap' f g h (Log    e)     = Log    (bimap' f g h e)
bimap' f g h (Neg    e)     = Neg    (bimap' f g h e)
bimap' f g h (Inv    e)     = Inv    (bimap' f g h e)
bimap' f g h (Add    e1 e2) = Add    (bimap' f g h e1) (bimap' f g h e2)
bimap' f g h (Mul    e1 e2) = Mul    (bimap' f g h e1) (bimap' f g h e2)
bimap' f g h (Less   e1 e2) = Less   (bimap' f g h e1) (bimap' f g h e2)
bimap' f g h (Weight e)     = Weight (bimap' f g h e)
bimap' f g h (Choice es)    = Choice (map (bimap' f g h) es)
bimap' f g h (Bind l r e)   = Bind (fmap' f l) (bimap' f g h r)
                                               (bimap' f g h e)
bimap' f g h x@(Dirac e)    = case typeOf x of Meas -> Dirac (bimap' f g h e)
bimap' f g h x@(Pair e1 e2) = case typeOf x of Prod -> Pair (bimap' f g h e1)
                                                            (bimap' f g h e2)
bimap' f g h x@(Inl e)      = case typeOf x of Sum -> Inl (bimap' f g h e)
bimap' f g h x@(Inr e)      = case typeOf x of Sum -> Inr (bimap' f g h e)
bimap' _ _ _ Unit           = Unit
bimap' _ g h x@(Closure e env) =
  case typeOf x of Meas -> h e [ Binding name (g u) | Binding name u <- env ]

vars :: (Type t, Monoid m) =>
        (forall tb. (Type tb) => Tree b tb ->
                    (forall tu. (Type tu) => u tu -> m) ->
                    (forall tu. (Type tu) => u tu -> m)) ->
        (forall tu. (Type tu) => u tu -> m) -> Expr b u t -> m
vars _ _ Lebesgue            = mempty
vars _ _ (LitReal _)         = mempty
vars _ _ Pi                  = mempty
vars _ f (Var u)             = f u
vars b f (Exp e)             = vars b f e
vars b f (Log e)             = vars b f e
vars b f (Neg e)             = vars b f e
vars b f (Inv e)             = vars b f e
vars b f (Add  e1 e2)        = vars b f e1 `mappend` vars b f e2
vars b f (Mul  e1 e2)        = vars b f e1 `mappend` vars b f e2
vars b f (Less e1 e2)        = vars b f e1 `mappend` vars b f e2
vars b f (Weight e)          = vars b f e
vars b f (Choice es)         = mconcat (map (vars b f) es)
vars b f (Bind lhs rhs body) = vars b f rhs `mappend` vars b (b lhs f) body
vars b f x@(Dirac e)         = case typeOf x of Meas -> vars b f e
vars b f x@(Pair e1 e2)      = case typeOf x of
                               Prod -> vars b f e1 `mappend` vars b f e2
vars b f x@(Inl e)           = case typeOf x of Sum -> vars b f e
vars b f x@(Inr e)           = case typeOf x of Sum -> vars b f e
vars _ _ Unit                = mempty
vars _ f (Closure e env)     = vars hideUse (f . (env !!)) e

hideUse :: (Type t', Monoid m) => Tree Name t' ->
           (forall t. (Type t) => Name t -> m) ->
           (forall t. (Type t) => Name t -> m)
hideUse lhs = \f u -> if S.member (Binding u (Const ())) bs then mempty else f u
  where bs = foldMap' (\u -> S.singleton (Binding u (Const ()))) lhs

instance Foldable' (Expr b) where foldMap' = vars (\_ f -> f)

------- Macros to make expressions more concise to write

stdRandom :: Expr Name Name (Measure Real)
stdRandom = Bind (Leaf u) Lebesgue
                 (condLess 0 (Var u) (condLess (Var u) 1 (Dirac (Var u))))
  where u = Const "u"

condLess :: Expr b u Real -> Expr b u Real ->
            Expr b u (Measure t) -> Expr b u (Measure t)
condLess e1 e2 = Bind (UnaryL Nil) (Dirac (Less e1 e2))

weight :: Expr b u Real -> Expr b u (Measure t) -> Expr b u (Measure t)
weight e = Bind Nil (Weight e)

-- TODO: Add pure `case' construct
if' :: Expr b u (Either () ()) ->
       Expr b u (Measure t) -> Expr b u (Measure t) -> Expr b u (Measure t)
if' e et ee = Choice [ Bind (UnaryL Nil) (Dirac e) et
                     , Bind (UnaryR Nil) (Dirac e) ee ]

max_ :: Expr b u Real -> Expr b u Real -> Expr b u (Measure Real)
max_ e1 e2 = if' (Less e1 e2) (Dirac e2) (Dirac e1)

instance Num (Expr b u Real) where
  (+)         = Add
  (*)         = Mul
  negate      = Neg
  abs         = error "TODO: Add pure `case' construct"
                -- \x -> if_ (Less 0 x) x (-x)
  signum      = error "TODO: Add pure `case' construct"
                -- \x -> if_ (Less 0 x) 1 (if_ (Less x 0) (-1) 0)
  fromInteger = LitReal . fromInteger

instance Fractional (Expr b u Real) where
  recip        = Inv
  fromRational = LitReal

ex :: (Type t) => Expr Void Loc t -> Expr Loc Loc t
ex = bimap' exFalso id Closure

------- The heap binds thunks to trees of locations

data Thunk t where
  Delayed :: Expr Name Name (Measure t) -> Env -> Thunk t
  Forced  :: Expr Void Loc t ->                   Thunk t

instance Show' Thunk where
  pretty' p (Delayed e env) = prettyFun (p > 10) "Delayed" $ parens
                            $ sep [pretty' 0 e, text "@" <+> pretty env]
  pretty' p (Forced e)      = prettyFun (p > 10) "Forced" $ pretty' 11 e

force :: (Expr Name Name (Measure t) -> Env -> a) ->
         (Expr Void Loc           t  -> ()  -> a) ->
         Thunk t -> a
force go _  (Delayed e env) = go e env
force _  go (Forced e)      = go e ()

data Heap = Heap { fresh :: Int, bound :: [Binding (Tree Loc) Thunk] }
  deriving (Show)

instance Pretty Heap where
  pretty h = text "Heap" <+> sep [pretty (fresh h), pretty (bound h)]

------- Monad with nondeterminism (making multiple attempts at disintegration),
------- state (threading the heap along), and continuation (for Bind-insertion)

newtype M a = M { unM :: forall w.
                         (a -> Heap -> [Expr Loc Loc (Measure w)])
                            -> Heap -> [Expr Loc Loc (Measure w)] }

instance Monad M where
  return a = M (\c -> c a)
  m >>= k  = M (\c -> unM m (\a -> unM (k a) c))

instance Functor M where fmap f m = m >>= return . f

instance Monoid (M a) where
  mempty                = M (\_ _ -> [])
  mappend (M m1) (M m2) = M (\c h -> m1 c h ++ m2 c h)
  mconcat ms            = M (\c h -> concatMap (\(M m) -> m c h) ms)

reject :: M a
reject = M (\_ _ -> [Choice []])

insert :: (forall w. Expr Loc Loc (Measure w) ->
                     Expr Loc Loc (Measure w)) -> M ()
insert f = M (\c h -> map f (c () h))

gensym :: M (Loc t)
gensym = M (\c h -> c (Const (fresh h)) h{fresh = succ (fresh h)})

------- Overload the evaluation and disintegration of input expressions
------- (Expr Name Name t) and output expressions (Expr Void Loc t)

class (Pretty env, Show' u) => Use env u where
  (!) :: (Type t) => env -> u t -> Loc t
  close :: Expr Name Name (Measure t) -> [Binding Name u] -> env ->
           (Expr Name Name (Measure t), Env)

instance Use Env Name where
  (!) = (!!)
  close e env = (,) (rename env (\lhs rhs -> Bind lhs (Dirac rhs) e)) where
    rename :: [Binding Name Name] ->
              (forall t. (Type t) => Tree Name t -> Expr Name Name t -> w) -> w
    rename []                       k = k Nil Unit
    rename (Binding a b : bindings) k = rename bindings (\lhs rhs ->
                                        k (Branch (Leaf a) lhs)
                                          (Pair (Var b) rhs))

instance Use () Loc where
  _ ! l = l
  close e env () = (e, env)

class (Use env u, Show' b) => Delay env b u where
  delay    :: (Type t) => Expr b u t -> env -> M (Expr Void Loc t)
  allocate :: (Type t) => Tree b t -> Expr b u (Measure t) -> env -> M env
  measure  :: Expr b u (Measure t) -> env -> Expr Void Loc (Measure t)

instance Delay Env Name Name where
  delay e env = M (\c h ->
    let l = Const (fresh h)
    in c (Var l)
         h{fresh = succ (fresh h),
           bound = Binding (Leaf l) (Delayed (Dirac e) env) : bound h})
  allocate lhs rhs env = M (\c h ->
    let step b = do loc <- get
                    put (succ loc)
                    tell [Binding b (Const loc)]
                    return (Const loc)
        (lhs', fresh', bindings) = runRWS (mapM' step lhs) () (fresh h)
        env' | unique bindings = bindings ++ env
             | otherwise = error ("Duplicate variable in " ++ show bindings)
    in c env'
         h{fresh = fresh',
           bound = Binding lhs' (Delayed rhs env) : bound h})
  measure = Closure

instance Delay () Void Loc where
  delay e () = return e
  allocate lhs rhs () = insert (Bind (fmap' exFalso lhs) (ex rhs)) >> return ()
  measure e () = e

------- Retrieving thunks from, and storing results in, the heap

data Retrieval to where
  Retrieval :: (Type t) => Selector to t -> Tree Loc t -> Thunk t ->
               Retrieval to

retrieve :: (Type to) => Loc to -> M (Maybe (Retrieval to))
retrieve loc = M (\c h ->
  case partitionEithers [ case locate loc lhs of
                                 Just s  -> Right (Retrieval s lhs thunk)
                                 Nothing -> Left entry
                        | entry@(Binding lhs thunk) <- bound h ] of
    (_   , []   ) -> c Nothing h
    (left, [r]  ) -> c (Just r) h{bound=left}
    (_   , _:_:_) -> error ("Duplicate heap entry " ++ show' 0 loc ""))

store :: (Type t) => Tree Loc t -> Expr Void Loc t -> M ()
store x@(Branch t1 t2) (Pair e1 e2) = case typeOf x of Prod -> do store t1 e1
                                                                  store t2 e2
store x@(UnaryL t)     (Inl e)      = case typeOf x of Sum -> store t e
store   (UnaryL _)     (Inr _)      = reject
store x@(UnaryR t)     (Inr e)      = case typeOf x of Sum -> store t e
store   (UnaryR _)     (Inl _)      = reject
store   Nil            Unit         = return ()
store   lhs            rhs          =
  M (\c h -> c () h{bound = Binding lhs (Forced rhs) : bound h})

value :: (Type t) => Loc t -> M (Expr Void Loc t)
value l = M (\c h ->
  let err = error ("Location " ++ show' 0 l " unexpectedly not bound alone") in
  case [ entry | entry@(Binding lhs _) <- bound h, isJust (locate l lhs) ] of
    [Binding (Leaf l') (Forced rhs)] ->
      case jmEq l l' of Just Refl -> c rhs h
                        _ -> err
    _ -> err)

------- Main evaluator

determine :: (Delay env b u, Type t) => Expr b u (Measure t) ->
             env -> Selector to t -> M (Expr Void Loc t)
determine e env s
  | traceShow (prettyFun False "determine"
                (sep [pretty' 11 e, pretty env, pretty' 11 s]))
              False = undefined
determine Lebesgue _ Root = do
  l <- gensym
  insert (Bind (Leaf l) Lebesgue)
  return (Var l)
determine e@(Var _) env s = do
  v <- evaluate e env Root
  case v of Var l -> do l' <- gensym
                        insert (Bind (Leaf l') (Var l))
                        return (Var l')
            _ -> determine v () s
determine (Weight e) env Root = do
  x <- evaluate e env Root
  case x of LitReal 1 -> return () -- trivial simplification
            _ -> insert (weight (ex x))
  return Unit
determine (Choice es) env s =
  M (\c h -> fmap Choice (mapM (\e -> unM (determine e env s) c h) es))
determine (Bind lhs rhs body) env s = do
  env' <- allocate lhs rhs env
  determine body env' s
determine (Dirac e) env s = evaluate e env s
determine (Closure e' env') env s = uncurry determine (close e' env' env) s

evaluate :: (Delay env b u, Type t) => Expr b u t ->
            env -> Selector to t -> M (Expr Void Loc t)
evaluate e env s
  | traceShow (prettyFun False "evaluate"
                (sep [pretty' 11 e, pretty env, pretty' 11 s]))
              False = undefined
evaluate Lebesgue _ Root = return Lebesgue
evaluate (LitReal x) _ Root = return (LitReal x)
evaluate Pi _ Root = return Pi
evaluate (Var v) env s = do
  let l = env ! v
  retrieval <- retrieve l
  case retrieval of Nothing -> return (Var l)
                    Just (Retrieval s' lhs thunk) -> do
                      rhs <- force determine evaluate thunk (compose s' s)
                      store lhs rhs
                      value l
evaluate (Exp e)      env Root = fmap   Exp  (evaluate e env Root)
evaluate (Log e)      env Root = fmap   Log  (evaluate e env Root)
evaluate (Neg e)      env Root = fmap   Neg  (evaluate e env Root)
evaluate (Inv e)      env Root = fmap   Inv  (evaluate e env Root)
evaluate (Add  e1 e2) env Root = liftM2 Add  (evaluate e1 env Root)
                                             (evaluate e2 env Root)
evaluate (Mul  e1 e2) env Root = liftM2 Mul  (evaluate e1 env Root)
                                             (evaluate e2 env Root)
evaluate (Less e1 e2) env Root = liftM2 Less (evaluate e1 env Root)
                                             (evaluate e2 env Root)
evaluate e@(Weight _)   env Root = return (measure e env)
evaluate e@(Choice _)   env Root = return (measure e env)
evaluate e@(Bind _ _ _) env Root = return (measure e env)
evaluate e@(Dirac _)    env Root = return (measure e env)
evaluate e@(Pair e1 e2) env Root =
  case typeOf e of Prod -> liftM2 Pair (delay e1 env) (delay e2 env)
evaluate e@(Pair e1 e2) env (Fst s) =
  case typeOf e of Prod -> liftM2 Pair (evaluate e1 env s) (delay e2 env)
evaluate e@(Pair e1 e2) env (Snd s) =
  case typeOf e of Prod -> liftM2 Pair (delay e1 env) (evaluate e2 env s)
evaluate e@(Inl e') env Root =
  case typeOf e of Sum -> fmap Inl (delay e' env)
evaluate e@(Inl e') env (Unl s) =
  case typeOf e of Sum -> fmap Inl (evaluate e' env s)
evaluate (Inl _) _ (Unr _) = reject
evaluate e@(Inr e') env Root =
  case typeOf e of Sum -> fmap Inr (delay e' env)
evaluate e@(Inr e') env (Unr s) =
  case typeOf e of Sum -> fmap Inr (evaluate e' env s)
evaluate (Inr _) _ (Unl _) = reject
evaluate Unit _ Root = return Unit
evaluate (Closure e' env') env Root =
  return (uncurry Closure (close e' env' env))

------- Main disintegrator

disintegrate :: (Delay env b u, Type t, Type to) => Expr b u (Measure t) ->
                env -> Selector to t -> Expr Void Loc to -> M (Expr Void Loc t)
disintegrate e env s t
  | traceShow (prettyFun False "disintegrate"
                (sep [pretty' 11 e, pretty env, pretty' 11 s, pretty' 11 t]))
              False = undefined
disintegrate Lebesgue _ Root t = return t
disintegrate e@(Var _) env s t = do
  v <- evaluate e env Root
  case v of Var _ -> mempty
            _ -> disintegrate v () s t
disintegrate e@(Weight _) env Root _ = determine e env Root
disintegrate (Choice es) env s t =
  M (\c h -> fmap Choice (mapM (\e -> unM (disintegrate e env s t) c h) es))
disintegrate (Bind lhs rhs body) env s t = do
  env' <- allocate lhs rhs env
  disintegrate body env' s t
disintegrate (Dirac e) env s t = propagate e env s t
disintegrate (Closure e' env') env s t =
  uncurry disintegrate (close e' env' env) s t

propagate :: (Delay env b u, Type t, Type to) => Expr b u t ->
             env -> Selector to t -> Expr Void Loc to -> M (Expr Void Loc t)
propagate e env s t
  | traceShow (prettyFun False "propagate"
                (sep [pretty' 11 e, pretty env, pretty' 11 s, pretty' 11 t]))
              False = undefined
propagate Lebesgue _ Root _ = mempty
propagate (LitReal _) _ Root _ = mempty
propagate Pi _ Root _ = mempty
propagate (Var v) env s t = do
  let l = env ! v
  retrieval <- retrieve l
  case retrieval of Nothing -> mempty
                    Just (Retrieval s' lhs thunk) -> do
                      rhs <- force disintegrate propagate thunk (compose s' s) t
                      store lhs rhs
                      value l
propagate (Exp e) env Root t = do insert (condLess 0 (ex t) .
                                          weight (Inv (ex t)))
                                  fmap Exp (propagate e env Root (Log t))
propagate (Log e) env Root t = do insert (weight (Exp (ex t)))
                                  fmap Log (propagate e env Root (Exp t))
propagate (Neg e) env Root t = fmap Neg (propagate e env Root (-t))
propagate (Inv e) env Root t = do insert (weight (Inv (ex t * ex t)))
                                  fmap Inv (propagate e env Root (Inv t))
propagate (Add e1 e2) env Root t = mappend (go e1 e2) (go e2 e1)
  where go e e' = do x1 <- evaluate e env Root
                     fmap (Add x1) (propagate e' env Root (t - x1))
propagate (Mul e1 e2) env Root t = mappend (go e1 e2) (go e2 e1)
  where go e e' = do x1 <- evaluate e env Root
                     insert (Bind Nil (if' (Less 0 (ex x1))
                                           (Weight (Inv (ex x1)))
                                           (Weight (Inv (-(ex x1))))))
                     fmap (Mul x1) (propagate e' env Root (t/x1))
propagate (Less e1 e2) env Root t = do
  x1 <- evaluate e1 env Root
  x2 <- evaluate e2 env Root
  let x = Less x1 x2
  M (\c h -> [ if' (ex x) (Bind (UnaryL Nil) (Dirac (ex t)) et)
                          (Bind (UnaryR Nil) (Dirac (ex t)) ef)
             | et <- c (Inl Unit) h
             , ef <- c (Inr Unit) h ])
propagate (Weight _) _ Root _ = mempty
propagate (Choice _) _ Root _ = mempty
propagate (Bind _ _ _) _ Root _ = mempty
propagate (Dirac _) _ Root _ = mempty
propagate e@(Pair e1 e2) env Root t =
  case typeOf e of
    Prod -> do l1 <- gensym
               l2 <- gensym
               insert (Bind (Branch (Leaf l1) (Leaf l2)) (Dirac (ex t)))
               liftM2 Pair (propagate e1 env Root (Var l1))
                           (propagate e2 env Root (Var l2))
propagate e@(Pair e1 e2) env (Fst s) t =
  case typeOf e of Prod -> liftM2 Pair (propagate e1 env s t) (delay e2 env)
propagate e@(Pair e1 e2) env (Snd s) t =
  case typeOf e of Prod -> liftM2 Pair (delay e1 env) (propagate e2 env s t)
propagate e@(Inl e') env Root t =
  case typeOf e of Sum -> do l <- gensym
                             insert (Bind (UnaryL (Leaf l)) (Dirac (ex t)))
                             fmap Inl (propagate e' env Root (Var l))
propagate e@(Inl e') env (Unl s) t =
  case typeOf e of Sum -> fmap Inl (propagate e' env s t)
propagate (Inl _) _   (Unr _) _ = reject
propagate e@(Inr e') env Root t =
  case typeOf e of Sum -> do l <- gensym
                             insert (Bind (UnaryR (Leaf l)) (Dirac (ex t)))
                             fmap Inr (propagate e' env Root (Var l))
propagate e@(Inr e') env (Unr s) t =
  case typeOf e of Sum -> fmap Inr (propagate e' env s t)
propagate (Inr _) _   (Unl _) _ = reject
propagate Unit _ Root _ = return Unit
propagate (Closure _ _) _ Root _ = mempty

------- To finish off evaluation or disintegration, we need to turn residual
------- heap entries into bindings and closures into monadic expressions

run :: (Type t) => M (Expr Void Loc t) -> [Expr Loc Loc (Measure t)]
run = run' 1

data Node = LHS (Binding (Tree Loc) (Expr Void Loc))
          | RHS (Binding Loc (Const ()))
  deriving (Eq, Ord)

run' :: (Type t) => Int -> M (Expr Void Loc t) -> [Expr Loc Loc (Measure t)]
run' l m = unM (do e <- m
                   traceHeap "Before determineHeap:"
                   determineHeap
                   traceHeap "After determineHeap:"
                   return (Dirac (ex e)))
               finish
               Heap{fresh = l, bound = []}
  where finish e0 h = [determineClosures (foldl f e0 b)]
          where f e (Binding lhs rhs) = Bind lhs (Dirac (ex rhs)) e
                b = [ Binding lhs rhs
                    | ((), LHS (Binding lhs rhs), _) <- map v (topSort g) ]
                (g,v,_) = graphFromEdges (concat
                  [ ((), LHS (Binding lhs e),
                         foldMap' (\u -> [RHS (Binding u (Const ()))])
                                  e)
                  : foldMap' (\u -> [((), RHS (Binding u (Const ())),
                                          [LHS (Binding lhs e)])])
                             lhs
                  | Binding lhs (Forced e) <- bound h ])

traceHeap :: String -> M ()
traceHeap label = M (\c h -> traceShow (text label <+> pretty h) (c () h))

data RetrievalThunk where
  RetrievalThunk :: (Type t) => Tree Loc t ->
                    Expr Name Name (Measure t) -> Env -> RetrievalThunk

retrieveThunk :: [Binding (Tree Loc) Thunk] ->
                 Maybe (RetrievalThunk, [Binding (Tree Loc) Thunk])
retrieveThunk [] = Nothing
retrieveThunk (b : bs) = case b of
  Binding lhs (Delayed e env) -> Just (RetrievalThunk lhs e env, bs)
  _ -> fmap (fmap (b:)) (retrieveThunk bs)

determineHeap :: M ()
determineHeap = M (\c h ->
  case retrieveThunk (bound h) of
    Nothing -> c () h
    Just (RetrievalThunk lhs e env, bs) ->
      unM (determine e env Root >>= store lhs >> determineHeap)
          c h{bound = bs})

newtype Max a = Max { getMax :: a }
instance (Ord a, Bounded a) => Monoid (Max a) where
  mempty = Max minBound
  mappend (Max a) (Max b) = Max (max a b)
  mconcat = Max . maximum . map getMax

determineClosures :: (Type t) => Expr Loc Loc t -> Expr Loc Loc t
determineClosures = bimap' id id $ \e env ->
  let f (Const n') = Max n'
      n = succ (max 0 (getMax (vars hideUse (f . (env !!)) e)))
      -- TODO: is the list below really always singleton?
      [result] = run' n (determine e env Root)
  in result

------- Conversion to Hakaru

toHakaru :: (Eq' u, Show' u, Mochastic repr, Type t') =>
            Expr u u t' -> (forall t. Type t => u t -> repr t) -> repr t'
toHakaru Lebesgue     _   = lebesgue
toHakaru (LitReal x)  _   = fromRational x
toHakaru Pi           _   = pi
toHakaru (Var u)      env = env u
toHakaru (Exp e)      env = exp (toHakaru e env)
toHakaru (Log e)      env = log (toHakaru e env)
toHakaru (Neg e)      env = negate (toHakaru e env)
toHakaru (Inv e)      env = recip (toHakaru e env)
toHakaru (Add e1 e2)  env = toHakaru e1 env + toHakaru e2 env
toHakaru (Mul e1 e2)  env = toHakaru e1 env * toHakaru e2 env
toHakaru (Less e1 e2) env = toHakaru e1 env `less` toHakaru e2 env
toHakaru (Weight e)   env = factor (unsafeProb (toHakaru e env))
toHakaru (Choice es)  env = superpose [ (1, toHakaru e env) | e <- es ]
toHakaru e@(Bind lhs rhs body) env =
  toHakaru rhs env `bind` \x ->
  matchHakaru lhs x (\bindings ->
  if unique bindings
  then toHakaru body (\v -> fromMaybe (env v) (lookup bindings v))
  else error ("Duplicate variable in " ++ show' 0 e ""))
toHakaru e@(Dirac e')   env = case typeOf e of Meas -> dirac (toHakaru e' env)
toHakaru e@(Pair e1 e2) env = case typeOf e of Prod -> pair (toHakaru e1 env)
                                                            (toHakaru e2 env)
toHakaru e@(Inl e')     env = case typeOf e of Sum  -> inl (toHakaru e' env)
toHakaru e@(Inr e')     env = case typeOf e of Sum  -> inr (toHakaru e' env)
toHakaru Unit           _   = unit
toHakaru (Closure e env) f  = toHakaru e (f . (env !!))

matchHakaru :: (Type t, Mochastic repr) => Tree u t -> repr t ->
               ([Binding u repr] -> repr (Measure w)) -> repr (Measure w)
matchHakaru (Branch t1 t2) x k =
  case typeOf x of Prod -> unpair x (\x1 x2 ->
                           matchHakaru t1 x1 (\b1 ->
                           matchHakaru t2 x2 (\b2 -> k (b1 ++ b2))))
matchHakaru (UnaryL t') x k =
  case typeOf x of Sum -> uneither x (\x' -> matchHakaru t' x' k)
                                     (\_ -> superpose [])
matchHakaru (UnaryR t') x k =
  case typeOf x of Sum -> uneither x (\_ -> superpose [])
                                     (\x' -> matchHakaru t' x' k)
matchHakaru Nil _ k = k []
matchHakaru (Leaf u) x k = k [Binding u x]

------- Conversion from Hakaru

newtype Disintegrate a = Disint
  (forall w. Cont (Int -> Expr Loc Loc (Measure w)) (Expr Loc Loc (Disint' a)))
type family Disint' (a :: *)
type instance Disint' Real         = Real
type instance Disint' Prob         = Real
type instance Disint' ()           = ()
type instance Disint' (a, b)       = (Disint' a, Disint' b)
type instance Disint' (Either a b) = Either (Disint' a) (Disint' b)
type instance Disint' (Measure a)  = Measure (Disint' a)
type instance Disint' (a -> b)     = Disint' a -> Disint' b

runDisintegrate :: forall a b repr. (Type a, Type b, Mochastic repr) =>
                   Disintegrate (Measure (a, b)) ->
                   [repr (Disint' a) -> repr (Measure (Disint' b))]
runDisintegrate (Disint m) =
  typeDisint (theType :: TypeOf a) $
  typeDisint (theType :: TypeOf b) $
  let nameOfLoc :: Loc t -> Name t
      nameOfLoc (Const i) = Const ('x' : show i)
      observed :: Loc (Disint' a)
      observed = Const 0
      e :: Expr Name Name (Measure (Disint' a, Disint' b))
      e = bimap' nameOfLoc nameOfLoc Closure (runCont m (\w _ -> w) 1)
  in [ \o -> liftM snd_ (toHakaru dis ([Binding observed o] !!))
     | dis <- run (disintegrate e emptyEnv (Fst Root) (Var observed)) ]

unDisint :: Disintegrate a ->
            (Expr Loc Loc (Disint' a) -> Int -> Expr Loc Loc (Measure w))
                                      -> Int -> Expr Loc Loc (Measure w)
unDisint (Disint m) = runCont m

typeDisint :: TypeOf t -> (Type (Disint' t) => w) -> w
typeDisint Real   k = k
typeDisint Prob   k = k
typeDisint One    k = k
typeDisint x@Meas k = typeDisint (typeOf2 x) k
typeDisint x@Prod k = typeDisint (typeOf1 x) (typeDisint (typeOf2 x) k)
typeDisint x@Sum  k = typeDisint (typeOf1 x) (typeDisint (typeOf2 x) k)
typeDisint x@Fun  k = typeDisint (typeOf1 x) (typeDisint (typeOf2 x) k)

insertDisint :: (Type t) => Disintegrate t
             -> (forall w. Type (Disint' t) => Expr Loc Loc (Disint' t) ->
                  (Expr Loc Loc (Disint' a) -> Int -> Expr Loc Loc (Measure w))
                                            -> Int -> Expr Loc Loc (Measure w))
             -> Disintegrate a
insertDisint d@(Disint x) f = typeDisint (typeOf d) (Disint (x >>= cont . f))

resetDisint :: (Type t) => Disintegrate t -> Disintegrate t
resetDisint d = typeDisint (typeOf d) (Disint (cont (\c i ->
  Bind (Leaf (Const i)) (unDisint d (\w _ -> Dirac w) i)
       (c (Var (Const i)) (succ i)))))

instance (Disint' t ~ Real) => Order Disintegrate t where
  less (Disint x) (Disint y) = Disint (fmap Less x <*> y)

instance (Type t, Disint' t ~ Real) => Num (Disintegrate t) where
  Disint x + Disint y = Disint (fmap Add x <*> y)
  Disint x * Disint y = Disint (fmap Mul x <*> y)
  negate (Disint x)   = Disint (fmap Neg x)
  abs x    = insertDisint x (\e c i ->
    Bind (Leaf (Const i))
         (if' (Less 0 e) (Dirac e) (Dirac (-e)))
         (c (Var (Const i)) (succ i)))
  signum x = insertDisint x (\e c i ->
    Bind (Leaf (Const i))
         (if' (Less 0 e) (Dirac (1 `asTypeOf` e)) (Dirac (-1)))
         (c (Var (Const i)) (succ i)))
  fromInteger x       = Disint (return (fromInteger x))

instance (Type t, Disint' t ~ Real) => Fractional (Disintegrate t) where
  recip (Disint x) = Disint (fmap Inv x)
  fromRational x   = Disint (return (fromRational x))

instance (Type t, Disint' t ~ Real) => Floating (Disintegrate t) where
  pi             = Disint (return Pi)
  exp (Disint x) = Disint (fmap Exp x)
  log (Disint x) = Disint (fmap Log x)
  sin            = error "Disintegrate: sin unimplemented"
  cos            = error "Disintegrate: cos unimplemented"
  sinh           = error "Disintegrate: sinh unimplemented"
  cosh           = error "Disintegrate: cosh unimplemented"
  asin           = error "Disintegrate: asin unimplemented"
  acos           = error "Disintegrate: acos unimplemented"
  atan           = error "Disintegrate: atan unimplemented"
  asinh          = error "Disintegrate: asinh unimplemented"
  acosh          = error "Disintegrate: acosh unimplemented"
  atanh          = error "Disintegrate: atanh unimplemented"

instance Base Disintegrate where
  unit = Disint (return Unit)
  pair (Disint x) (Disint y) = Disint (fmap Pair x <*> y)
  unpair xy k = insertDisint xy (\e c i ->
    let x = Const i
        y = Const (i+1)
    in Bind (Branch (Leaf x) (Leaf y)) (Dirac e)
            (unDisint (k (Disint (return (Var x))) (Disint (return (Var y))))
                      c
                      (i+2)))
  inl (Disint x) = Disint (fmap Inl x)
  inr (Disint x) = Disint (fmap Inr x)
  uneither xy kx ky = insertDisint xy (\e c i ->
    Choice [ let x = Const i
             in Bind (UnaryL (Leaf x)) (Dirac e)
                     (unDisint (kx (Disint (return (Var x)))) c (i+1))
           , let y = Const i
             in Bind (UnaryR (Leaf y)) (Dirac e)
                     (unDisint (ky (Disint (return (Var y)))) c (i+1)) ])
  unsafeProb (Disint x) = Disint x
  fromProb (Disint x) = Disint x
  betaFunc = error "Disintegrate: betaFunc unimplemented"

instance Mochastic Disintegrate where
  dirac x = Disint (cont (\c i -> c (unDisint x (\w _ -> Dirac w) i) i))
  bind d@(Disint x) k = typeDisint (typeOf2 d) (Disint (cont (\c i ->
    c (Bind (Leaf (Const i))
            (runCont x (\w _ -> w) i)
            (unDisint (k (Disint (return (Var (Const i)))))
                      (\w _ -> w)
                      (i+1)))
      i)))
  lebesgue = Disint (return Lebesgue)
  superpose pms = Disint (cont (\c i ->
    c (Choice
       [ Bind Nil
              (runCont p (\w _ -> Weight w) i)
              (runCont m (\w _ -> w) i)
       | (Disint p, Disint m) <- pms ])
      i))
