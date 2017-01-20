{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE EmptyCase                 #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE KindSignatures            #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE PolyKinds                 #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeOperators             #-}
module Language.Hakaru.Syntax.ANF where

--------------------------------------------------------------------------------
-- An implementation of A-normalization as described in
--   https://pdfs.semanticscholar.org/5da1/4c8b7851e56e4bf08e30db4ced54be989768.pdf
-- A-normalization is not strictly necessary, but make implementing later
-- transformations easy, as all non-trivial operations are assigned names.
--
-- The planned pipeline:
-- 1. ANF conversion
-- 2. Expression hoising (perform operations as soon as their data dependencies
--    are satisified)
-- 3. (Conditional hoisting)
-- 4. CSE (in order to clean up work duplicated by hoisting)
--------------------------------------------------------------------------------

import           Prelude                          hiding (product, (+))

import           Data.Number.Nat
import           Data.IntMap                      (IntMap)
import qualified Data.IntMap                      as IM
import           Data.Sequence                    (ViewL (..), (<|))
import qualified Data.Sequence                    as S

import           Language.Hakaru.Syntax.ABT
import           Language.Hakaru.Syntax.AST
import           Language.Hakaru.Syntax.Datum
import           Language.Hakaru.Syntax.DatumCase
import           Language.Hakaru.Syntax.IClasses
import           Language.Hakaru.Syntax.TypeOf
import           Language.Hakaru.Syntax.Value
import           Language.Hakaru.Syntax.Variable
import           Language.Hakaru.Types.Coercion
import           Language.Hakaru.Types.DataKind
import           Language.Hakaru.Types.HClasses
import           Language.Hakaru.Types.Sing

import           Language.Hakaru.Syntax.Prelude

example1 = binder "a" sing $ \ a -> (triv $ real_ 1 + a)

example2 = let_ (nat_ 1) $ \ a -> triv ((summate a (a + (nat_ 10)) (\i -> i)) +
                                        (product a (a + (nat_ 10)) (\i -> i)))

data EAssoc =
    forall (a :: Hakaru) . EAssoc {-# UNPACK #-} !(Variable a) {-# UNPACK #-} !(Variable a)

newtype Env = Env (IM.IntMap EAssoc)

emptyEnv :: Env
emptyEnv = Env IM.empty

updateEnv :: forall (a :: Hakaru) . Variable a -> Variable a -> Env -> Env
updateEnv vin vout = updateEnv' (EAssoc vin vout)

updateEnv' :: EAssoc -> Env -> Env
updateEnv' v@(EAssoc x _) (Env xs) =
    Env $ IM.insert (fromNat $ varID x) v xs

lookupVar :: forall (a :: Hakaru) . Variable a -> Env -> Maybe (Variable a)
lookupVar x (Env env) = do
    EAssoc v1 v2 <- IM.lookup (fromNat $ varID x) env
    Refl         <- varEq x v1
    return $ v2

-- | The context in which A-normalization occurs. Represented as a continuation,
-- the context expects an expression of a particular type (usually a variable)
-- and produces a new expression as a result.
type Context abt a b = abt '[] a -> abt '[] b

-- | Entry point for the normalization process. Initializes normalize' with the
-- empty context.
normalize
  :: (ABT Term abt)
  => abt '[] a
  -> abt '[] a
normalize abt = normalize' abt emptyEnv id

normalize'
  :: (ABT Term abt)
  => abt '[] a
  -> Env
  -> Context abt a b
  -> abt '[] b
normalize' abt env ctxt = (caseVarSyn abt normalizeVar normalizeTerm) env ctxt

normalizeVar :: (ABT Term abt) => (Variable a) -> Env -> Context abt a b -> abt '[] b
normalizeVar v env ctxt =
  case lookupVar v env of
    Just v' -> ctxt (var v')
    Nothing -> ctxt (var v)

isValue
  :: (ABT Term abt)
  => abt '[] a
  -> Bool
isValue abt = caseVarSyn abt (const True) isValueTerm
  where
    isValueTerm Literal_{}  = True
    isValueTerm Datum_{}    = True
    isValueTerm (Lam_ :$ _) = True
    isValueTerm _           = False

normalizeTerm
  :: (ABT Term abt)
  => Term abt a
  -> Env
  -> Context abt a b
  -> abt '[] b
normalizeTerm (NaryOp_ op args) = normalizeNaryOp op args
normalizeTerm (x :$ args)       = normalizeSCon x args
normalizeTerm (Case_ c bs)      = normalizeCase c bs
normalizeTerm term              = const ($ syn term)

normalizeCase
  :: forall a b c abt . (ABT Term abt)
  => abt '[] a
  -> [Branch a abt b]
  -> Env
  -> Context abt b c
  -> abt '[] c
normalizeCase cond bs env ctxt =
  normalizeName cond env $ \ cond' ->
    let norm :: abt '[] a -> abt '[] a
        norm b = normalize' b env id

        normalizeBranch :: Branch a abt b -> Branch a abt b
        normalizeBranch (Branch pat body) =
          case pat of
            PWild -> Branch PWild (normalize' body env id)
            PVar  -> caseBind body $ \v body' ->
                       Branch PVar $ binder "" (varType v) $ \v' ->
                         let var  = getVar v'
                             env' = updateEnv v var env
                         in normalize' body' env' id

        bs' = map normalizeBranch bs
    in ctxt $ syn (Case_ cond bs')

normalizeName
  :: (ABT Term abt)
  => abt '[] a
  -> Env
  -> Context abt a b
  -> abt '[] b
normalizeName abt env ctxt = normalize' abt env giveName
  where
    giveName abt' | isValue abt' = ctxt abt'
                  | otherwise    = let_ abt' ctxt

normalizeNames
  :: (ABT Term abt)
  => S.Seq (abt '[] a)
  -> Env
  -> (S.Seq (abt '[] a) -> abt '[] b)
  -> abt '[] b
normalizeNames abts env = foldr f ($ S.empty) abts
  where
    f x acc ctxt = normalizeName x env $ \t -> acc (ctxt . (t <|))

normalizeNaryOp
  :: (ABT Term abt)
  => NaryOp a
  -> S.Seq (abt '[] a)
  -> Env
  -> Context abt a b
  -> abt '[] b
normalizeNaryOp op args env ctxt_ = normalizeNames args env (ctxt_ . syn . NaryOp_ op)

getVar :: (ABT Term abt) => abt '[] a -> Variable a
getVar abt = caseVarSyn abt (\ v@Variable{} -> v)
                            (const $ error "getVar: not given a variable")

normalizeSCon
  :: (ABT Term abt)
  => SCon args a
  -> SArgs abt args
  -> Env
  -> Context abt a b
  -> abt '[] b

normalizeSCon Lam_ =
  \(body :* End) env ctxt -> caseBind body $
    \v body' ->
      let f var = normalize' body' (updateEnv v (getVar var) env) id
      in ctxt $ syn (Lam_ :$ binder "" (varType v) f :* End)

normalizeSCon Let_ =
  \(rhs :* body :* End) env ctxt -> caseBind body $
    \v body' ->
      normalize' rhs env $ \rhs' ->
        let_ rhs' $ \v' ->
          let var  = getVar v'
              env' = updateEnv v var env
          in normalize' body' env' ctxt

-- TODO: Remove code duplication between sum and product cases
normalizeSCon s@Summate{} =
  \(lo :* hi :* body :* End) env ctxt ->
    normalizeName lo env $ \lo' ->
    normalizeName hi env $ \hi' ->
    caseBind body $ \v body' ->
      let body'' = bind v (normalize body')
      in ctxt $ syn (s :$ lo' :* hi' :* body'' :* End)

normalizeSCon p@Product{} =
  \(lo :* hi :* body :* End) env ctxt ->
    normalizeName lo env $ \lo' ->
    normalizeName hi env $ \hi' ->
    caseBind body $ \v body' ->
      let body'' = bind v (normalize body')
      in ctxt $ syn (p :$ lo' :* hi' :* body'' :* End)

normalizeSCon (ArrayOp_ op)  = undefined -- flattenArrayOp op

normalizeSCon op@(PrimOp_ _) = undefined
