{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
module Microc.Codegen (codegenProgram) where

import qualified LLVM.AST.IntegerPredicate as IP
import qualified LLVM.AST.FloatingPointPredicate as FP
import qualified LLVM.AST as AST
import qualified LLVM.AST.Operand as AST
import qualified LLVM.AST.Type as AST
import qualified LLVM.AST.Typed as AST
import LLVM.AST.Name

import qualified LLVM.IRBuilder.Module as L
import qualified LLVM.IRBuilder.Monad as L
import LLVM.IRBuilder.Monad (IRBuilderT)
import LLVM.IRBuilder.Module (liftModuleState, MonadModuleBuilder)
import LLVM.IRBuilder.Internal.SnocList
import qualified LLVM.IRBuilder.Instruction as L
import qualified LLVM.IRBuilder.Constant as L

import qualified Data.Map as M
import Control.Monad.State
import Control.Monad.Identity
import Data.String (fromString)

import qualified Microc.Semant as Semant
import Microc.Sast
import Microc.Ast (Type(..), Op(..), Uop(..), Function(..))

-- When using the IRBuilder, both functions and variables have the type Operand
type Env = M.Map String AST.Operand
type Codegen = L.IRBuilderT (State Env)
type LLVM = L.ModuleBuilderT (State Env)


ltypeOfTyp :: Type -> AST.Type
ltypeOfTyp TyVoid = AST.void
ltypeOfTyp TyInt = AST.i32
ltypeOfTyp TyFloat = AST.double
ltypeOfTyp TyBool = AST.IntegerType 1

codegenSexpr :: (MonadState Env m, L.MonadIRBuilder m) => SExpr -> m AST.Operand
codegenSexpr (TyInt, SLiteral i) = L.int32 (fromIntegral i)
codegenSexpr (TyFloat, SFliteral f) = L.double f
codegenSexpr (TyBool, SBoolLit b) = L.bit (if b then 1 else 0)
codegenSexpr (ty, SId name) = do
  vars <- get
  case M.lookup name vars of
    Just addr -> L.load addr 0
    Nothing -> error $ "Internal error - undefined variable name " ++ name 

codegenSexpr (TyInt, SBinop op lhs rhs) = do
  lhs' <- codegenSexpr lhs
  rhs' <- codegenSexpr rhs
  (case op of Add -> L.add; Sub -> L.sub; 
              Mult -> L.mul; Div -> L.sdiv; 
              Equal -> L.icmp IP.EQ; Neq -> L.icmp IP.NE; 
              Less -> L.icmp IP.SLT; Leq -> L.icmp IP.SLE; 
              Greater -> L.icmp IP.SGT; Geq -> L.icmp IP.SGE;
              _ -> error "Internal error - semant failed") lhs' rhs'
codegenSexpr (TyFloat, SBinop op lhs rhs) = do
  lhs' <- codegenSexpr lhs
  rhs' <- codegenSexpr rhs
  (case op of Add -> L.fadd; Sub -> L.fsub; 
              Mult -> L.fmul; Div -> L.fdiv;
              Equal -> L.fcmp FP.OEQ; Neq -> L.fcmp FP.ONE; 
              Less -> L.fcmp FP.OLT; Leq -> L.fcmp FP.OLE; 
              Greater -> L.fcmp FP.OGT; Geq -> L.fcmp FP.OGE;
              _ -> error "Internal error - semant failed") lhs' rhs'
codegenSexpr (TyBool, SBinop op lhs rhs) = do
  lhs' <- codegenSexpr lhs
  rhs' <- codegenSexpr rhs
  (case op of And -> L.and; Or -> L.or; 
              _ -> error "Internal error - semant failed") lhs' rhs'

-- The Haskell LLVM bindings don't provide numerical or boolean negation
-- primitives, but they're easy enough to emit ourselves
codegenSexpr (TyInt, SUnop Neg e) = do 
  zero <- L.int32 0; e' <- codegenSexpr e; L.sub zero e'
codegenSexpr (TyFloat, SUnop Neg e) = do
  zero <- L.double 0; e' <- codegenSexpr e; L.fsub zero e'
codegenSexpr (TyBool, SUnop Not e) = do
  true <- L.bit 1; e' <- codegenSexpr e; L.xor true e'

codegenSexpr (_, SAssign name e) = error "assignment not yet implemented"

codegenSexpr (_, SCall fun es) = do
  es' <- mapM (\e -> do e' <- codegenSexpr e; return (e', [])) es
  f <- gets $ \env -> env M.! fun
  L.call f es'

codegenSexpr (_, SNoexpr) = L.int32 0
-- Final catchall
codegenSexpr sx = 
  error $ "Internal error - semant failed. Invalid sexpr " ++ show sx

codegenStatement :: (MonadState Env m, L.MonadIRBuilder m) => SStatement -> m ()
codegenStatement (SExpr e) = void $ codegenSexpr e
codegenStatement (SReturn e) = codegenSexpr e >>= L.ret

codegenStatement (SBlock ss) = mapM_ codegenStatement ss

codegenStatement _ = error "If, for, and while WIP"

codegenFunc :: SFunction -> LLVM ()
codegenFunc f = do
  let name = mkName (sname f)
      mkParam (t, n) = (ltypeOfTyp t, L.ParameterName (fromString n))
      args = map mkParam (sformals f)
      retty = ltypeOfTyp (styp f)
      body params = do
        _entry <- L.block `L.named` "entry"
        env <- get
        forM_ args $ \(t, n) -> do
          addr <- L.alloca t Nothing 0
          L.store addr 0 (AST.LocalReference t (fromString $ show n))
          modify $ M.insert (show n) addr
          -- also need to do locals later
        mapM_ codegenStatement (sbody f)
  fun <- L.function name args retty body
  modify $ M.insert (sname f) fun

emitBuiltIns :: LLVM ()
emitBuiltIns = mapM_ emitBuiltIn (convert Semant.builtIns)
  where
    convert = map snd . M.toList
    emitBuiltIn f = 
      let fname = mkName (name f)
          paramTypes = map (ltypeOfTyp . fst) (formals f)
          retType = ltypeOfTyp (typ f)
      in do
        fun <- L.extern fname paramTypes retType
        modify $ M.insert (name f) fun

codegenProgram :: SProgram -> AST.Module
codegenProgram (globals, funcs) = flip evalState M.empty $ L.buildModuleT "microc" $ do
  emitBuiltIns 
  mapM_ codegenFunc funcs