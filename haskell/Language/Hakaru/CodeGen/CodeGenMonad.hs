{-# LANGUAGE CPP,
             DataKinds,
             FlexibleContexts,
             FlexibleInstances,
             GADTs,
             KindSignatures,
             StandaloneDeriving,
             RankNTypes        #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

----------------------------------------------------------------
--                                                    2016.07.01
-- |
-- Module      :  Language.Hakaru.CodeGen.CodeGenMonad
-- Copyright   :  Copyright (c) 2016 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  zsulliva@indiana.edu
-- Stability   :  experimental
-- Portability :  GHC-only
--
--   This module provides a monad for C code generation as well
-- as some useful helper functions for manipulating it
----------------------------------------------------------------


module Language.Hakaru.CodeGen.CodeGenMonad
  ( CodeGen
  , runCodeGen

  -- effects
  , declare
  , assign
  , putStat
  , extDeclare

  , genIdent
  , genIdent'

  -- Hakaru specific
  , createIdent
  , lookupIdent

  -- control mechanisms
  , whileCG
  , doWhileCG
  , forCG
  ) where

import Control.Monad.State

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative ((<$>))
#endif

import Language.Hakaru.Syntax.ABT hiding (var)
import Language.Hakaru.Types.DataKind
import Language.Hakaru.CodeGen.HOAS.Statement

import Language.C.Data.Ident
import Language.C.Data.Node
import Language.C.Syntax.AST

import Data.Number.Nat (fromNat)
import qualified Data.IntMap as IM
import qualified Data.Text   as T

----------------------------------------------------------------
-- Deriving Eq instances for C ASTs

-- this is done in this module because the CodeGen monad is the
-- only thing that cares about the uniqueness of generated code
-- Orphaned instances beware

deriving instance Eq (CExternalDeclaration NodeInfo)
deriving instance Eq (CDeclaration NodeInfo)
deriving instance Eq (CStringLiteral NodeInfo)
deriving instance Eq (CExpression NodeInfo)
deriving instance Eq (CFunctionDef NodeInfo)
deriving instance Eq (CInitializer NodeInfo)
deriving instance Eq (CDeclarator NodeInfo)
deriving instance Eq (CDerivedDeclarator NodeInfo)
deriving instance Eq (CPartDesignator NodeInfo)
deriving instance Eq (CDeclarationSpecifier NodeInfo)
deriving instance Eq (CTypeSpecifier NodeInfo)
deriving instance Eq (CTypeQualifier NodeInfo)
deriving instance Eq (CAttribute NodeInfo)
deriving instance Eq (CStatement NodeInfo)
deriving instance Eq (CArraySize NodeInfo)
deriving instance Eq (CStructureUnion NodeInfo)
deriving instance Eq (CConstant NodeInfo)
deriving instance Eq (CEnumeration NodeInfo)
deriving instance Eq (CCompoundBlockItem NodeInfo)
deriving instance Eq (CBuiltinThing NodeInfo)
deriving instance Eq (CAssemblyStatement NodeInfo)
deriving instance Eq (CAssemblyOperand NodeInfo)



suffixes :: [String]
suffixes = filter (\n -> not $ elem (head n) ['0'..'9']) names
  where base :: [Char]
        base = ['0'..'9'] ++ ['a'..'z']
        names = [[x] | x <- base] `mplus` (do n <- names
                                              [n++[x] | x <- base])


-- CG after "codegen", holds the state of a codegen computation
data CG = CG { freshNames   :: [String]
             , extDecls     :: [CExtDecl]
             , declarations :: [CDecl]
             , statements   :: [CStat]    -- statements can include assignments as well as other side-effects
             , varEnv       :: Env      }

emptyCG :: CG
emptyCG = CG suffixes [] [] [] emptyEnv

type CodeGen = State CG

runCodeGen :: CodeGen a -> ([CExtDecl],[CDecl], [CStat])
runCodeGen m =
  let (_, cg) = runState m emptyCG
  in  ( reverse $ extDecls     cg
      , reverse $ declarations cg
      , reverse $ statements   cg )

genIdent :: CodeGen Ident
genIdent = do cg <- get
              put $ cg { freshNames = tail $ freshNames cg }
              return $ builtinIdent $ "_" ++ (head $ freshNames cg)

genIdent' :: String -> CodeGen Ident
genIdent' s = do cg <- get
                 put $ cg { freshNames = tail $ freshNames cg }
                 return $ builtinIdent $ s ++ "_" ++ (head $ freshNames cg)

createIdent :: Variable (a :: Hakaru) -> CodeGen Ident
createIdent var@(Variable name _ _) =
  do cg <- get
     let ident = builtinIdent $ (T.unpack name) ++ "_" ++ (head $ freshNames cg)
         env'  = updateEnv (EAssoc var ident) (varEnv cg)
     put $ cg { freshNames = tail $ freshNames cg
              , varEnv     = env' }
     return ident

lookupIdent :: Variable (a :: Hakaru) -> CodeGen Ident
lookupIdent var = do cg <- get
                     case lookupVar var (varEnv cg) of
                       Nothing -> error $ "lookupIdent: var not found"
                       Just i  -> return i

declare :: CDecl -> CodeGen ()
declare d = do cg <- get
               put $ cg { declarations = d:(declarations cg) }

putStat :: CStat -> CodeGen ()
putStat s = do cg <- get
               put $ cg { statements = s:(statements cg) }

assign :: Ident -> CExpr -> CodeGen ()
assign v e = putStat (assignS v e)


extDeclare :: CExtDecl -> CodeGen ()
extDeclare d = do cg <- get
                  put $ cg { extDecls = d:(extDecls cg) }

---------
-- ENV --
---------

data EAssoc =
    forall (a :: Hakaru). EAssoc !(Variable a) !Ident

newtype Env = Env (IM.IntMap EAssoc)

emptyEnv :: Env
emptyEnv = Env IM.empty

updateEnv :: EAssoc -> Env -> Env
updateEnv v@(EAssoc x _) (Env xs) =
    Env $ IM.insert (fromNat $ varID x) v xs

lookupVar :: Variable (a :: Hakaru) -> Env -> Maybe Ident
lookupVar x (Env env) = do
    EAssoc _ e' <- IM.lookup (fromNat $ varID x) env
    -- Refl         <- varEq x x' -- extra check?
    return e'

----------------------------------------------------------------
-- Control Flow

whileCG :: CExpr -> CodeGen () -> CodeGen ()
whileCG bE m =
  let (_,_,stmts) = runCodeGen m
  in putStat $ whileS bE stmts

doWhileCG :: CExpr -> CodeGen () -> CodeGen ()
doWhileCG bE m =
  let (_,_,stmts) = runCodeGen m
  in putStat $ doWhileS bE stmts

forCG :: CExpr -> CExpr -> CExpr -> CodeGen () -> CodeGen ()
forCG _ _ _ _ = undefined
