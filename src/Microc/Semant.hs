{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
module Microc.Semant
  ( checkProgram
  )
where

import           Microc.Ast
import           Microc.Sast
import           Microc.Semant.Error
import           Microc.Semant.Analysis
import           Microc.Utils
import qualified Data.Map                      as M
import           Control.Monad.State
import           Control.Monad.Except
import           Data.Maybe                     ( isJust )
import           Data.Text                      ( Text )
import           Data.List                      ( find )

type Vars = M.Map (Text, VarKind) Type
type Funcs = M.Map Text Function

data Env = Env { vars     :: Vars
               , funcs    :: Funcs
               , thisFunc :: Function }

type Semant = ExceptT SemantError (State Env)

checkBinds :: VarKind -> [Bind] -> Semant [Bind]
checkBinds kind binds = do
  currentFunc <- if kind == Global
    then return Nothing
    else Just <$> gets thisFunc
  forM binds $ \case
    Bind TyVoid name -> throwError $ IllegalBinding name Void kind currentFunc

    Bind ty     name -> do
      vars <- gets vars
      unless (M.notMember (name, kind) vars) $ throwError $ IllegalBinding
        name
        Duplicate
        kind
        currentFunc
      modify $ \env -> env { vars = M.insert (name, kind) ty vars }
      return $ Bind ty name

builtIns :: Funcs
builtIns =
  M.fromList
    $ ( "alloc_ints"
      , Function (Pointer TyInt) "alloc_ints" [Bind TyInt "n"] [] []
      )
    : map
        toFunc
        [ ("print"   , TyInt)
        , ("printb"  , TyBool)
        , ("printf"  , TyFloat)
        , ("printbig", TyInt)
        ]
  where toFunc (name, ty) = (name, Function TyVoid name [Bind ty "x"] [] [])

checkExpr :: Expr -> Semant SExpr
checkExpr expr
  = let isNumeric t = t `elem` [TyInt, TyFloat]
    in
      case expr of
        Literal  i -> return (TyInt, SLiteral i)
        Fliteral f -> return (TyFloat, SFliteral f)
        BoolLit  b -> return (TyBool, SBoolLit b)
        Noexpr     -> return (TyVoid, SNoexpr)

        Id s       -> do
          vars <- gets vars
          let foundVars =
                map (\kind -> M.lookup (s, kind) vars) [Local, Formal, Global]
          case join $ find isJust foundVars of
            Nothing -> throwError $ UndefinedSymbol s Var expr
            Just ty -> return (ty, SId s)

        Binop op lhs rhs -> do
          lhs'@(t1, _) <- checkExpr lhs
          rhs'@(t2, _) <- checkExpr rhs

          let
            assertSym =
              unless (t1 == t2) $ throwError $ TypeError [t1] t2 (Expr expr)
            checkArith =
              unless (isNumeric t1)
                     (throwError $ TypeError [TyInt, TyFloat] t1 (Expr expr))
                >> return (t1, SBinop op lhs' rhs')

            checkBool =
              unless (t1 == TyBool)
                     (throwError $ TypeError [TyBool] t1 (Expr expr))
                >> return (t1, SBinop op lhs' rhs')
          case op of
            Add
              -> let rhs'' = SBinop Add lhs' rhs'
                 in
                   case (t1, t2) of
                     (Pointer t, TyInt    ) -> return (Pointer t, rhs'')
                     (TyInt    , Pointer t) -> return (Pointer t, rhs'')
                     (TyInt    , TyInt    ) -> return (TyInt, rhs'')
                     (TyFloat  , TyFloat  ) -> return (TyFloat, rhs'')
                     _                      -> throwError $ TypeError
                       [Pointer TyVoid, TyInt, TyFloat]
                       t1
                       (Expr expr)
            Sub
              -> let rhs'' = SBinop Sub lhs' rhs'
                 in
                   case (t1, t2) of
                     (Pointer t, TyInt     ) -> return (Pointer t, rhs'')
                     (TyInt    , Pointer t ) -> return (Pointer t, rhs'')
                     (Pointer t, Pointer t') -> if t == t'
                       then return (Pointer t, rhs'')
                       else throwError
                         $ TypeError [Pointer t'] (Pointer t) (Expr expr)
                     (TyInt  , TyInt  ) -> return (TyInt, rhs'')
                     (TyFloat, TyFloat) -> return (TyFloat, rhs'')
                     _                  -> throwError $ TypeError
                       [Pointer TyVoid, TyInt, TyFloat]
                       t1
                       (Expr expr)

            Mult   -> assertSym >> checkArith
            Div    -> assertSym >> checkArith
            BitAnd -> assertSym >> checkArith
            BitOr  -> assertSym >> checkArith
            And    -> assertSym >> checkBool
            Or     -> assertSym >> checkBool
            -- Power operator no longer exists in Sast
            Power  -> do
              unless (t1 == TyFloat)
                     (throwError $ TypeError [TyFloat] t1 (Expr expr))
              return (TyFloat, SCall "llvm.pow" [lhs', rhs'])

            Assign -> case snd lhs' of
              SId _         -> return (t1, SBinop Assign lhs' rhs')
              SUnop Deref _ -> return (t1, SBinop Assign lhs' rhs')
              _             -> throwError $ AssignmentError lhs rhs

            _relational -> do
              assertSym
              unless (isNumeric t1) $ throwError $ TypeError [TyInt, TyFloat]
                                                             t1
                                                             (Expr expr)
              return (TyBool, SBinop op lhs' rhs')

        Unop op e -> do
          e'@(ty, _) <- checkExpr e
          case op of
            Neg -> do
              unless (isNumeric ty) $ throwError $ TypeError [TyInt, TyFloat]
                                                             ty
                                                             (Expr expr)
              return (ty, SUnop Neg e')
            Not -> do
              unless (ty == TyBool) $ throwError $ TypeError [TyBool]
                                                             ty
                                                             (Expr expr)
              return (ty, SUnop Not e')
            Deref -> case ty of
              Pointer t -> return (t, SUnop Deref e')
              _         -> throwError $ TypeError
                [Pointer TyVoid, Pointer TyInt, Pointer TyFloat]
                ty
                (Expr expr)

            Addr -> return (Pointer ty, SUnop Addr e')


        Call s es -> do
          funcs <- gets funcs
          case M.lookup s funcs of
            Nothing -> throwError $ UndefinedSymbol s Func expr
            Just f  -> do
              es' <- mapM checkExpr es
              -- Check that the correct number of arguments was provided
              let nFormals = length (formals f)
                  nActuals = length es
              unless (nFormals == nActuals) $ throwError $ ArgError nFormals
                                                                    nActuals
                                                                    expr
              -- Check that types of arguments match
              forM_ (zip (map fst es') (map (\(Bind ty _) -> ty) (formals f)))
                $ \(callSite, defSite) ->
                    unless (callSite == defSite) $ throwError $ TypeError
                      { expected = [defSite]
                      , got      = callSite
                      , errorLoc = Expr expr
                      }
              return (typ f, SCall s es')

checkStatement :: Statement -> Semant SStatement
checkStatement stmt = case stmt of
  Expr e           -> SExpr <$> checkExpr e

  If pred cons alt -> do
    pred'@(ty, _) <- checkExpr pred
    unless (ty == TyBool) $ throwError $ TypeError [TyBool] ty stmt
    SIf pred' <$> checkStatement cons <*> checkStatement alt

  For init cond inc action -> do
    cond'@(ty, _) <- checkExpr cond
    unless (ty == TyBool) $ throwError $ TypeError [TyBool] ty stmt
    init'   <- checkExpr init
    inc'    <- checkExpr inc
    action' <- checkStatement action
    return $ SFor init' cond' inc' action'

  While cond action -> do
    cond'@(ty, _) <- checkExpr cond
    unless (ty == TyBool) $ throwError $ TypeError [TyBool] ty stmt
    SWhile cond' <$> checkStatement action

  Return expr -> do
    e@(ty, _) <- checkExpr expr
    fun       <- gets thisFunc
    unless (ty == typ fun) $ throwError $ TypeError [typ fun] ty stmt
    return $ SReturn e

  Block sl -> do
    let flattened = flatten sl
    unless (nothingFollowsRet flattened) $ throwError (DeadCode stmt)
    SBlock <$> mapM checkStatement sl
   where
    flatten []             = []
    flatten (Block s : ss) = flatten (s ++ ss)
    flatten (s       : ss) = s : flatten ss

    nothingFollowsRet []         = True
    nothingFollowsRet [Return _] = True
    nothingFollowsRet (s : ss  ) = case s of
      Return _ -> False
      _        -> nothingFollowsRet ss

checkFunction :: Function -> Semant SFunction
checkFunction func = do
  -- add the fname to the table and check for conflicts
  funcs <- gets funcs
  unless (M.notMember (name func) funcs) $ throwError $ Redeclaration
    (name func)
  -- add this func to symbol table
  modify
    $ \env -> env { funcs = M.insert (name func) func funcs, thisFunc = func }

  (formals', locals', body') <- locally $ liftM3
    (,,)
    (checkBinds Formal (formals func))
    (checkBinds Local (locals func))
    (checkStatement (Block $ body func))

  case body' of
    SBlock body'' -> do
      unless (typ func == TyVoid || validate (genCFG body''))
        $ throwError (TypeError [typ func] TyVoid (Block $ body func))

      return $ SFunction
        { styp     = typ func
        , sname    = name func
        , sformals = formals'
        , slocals  = locals'
        , sbody    = SBlock body''
        }
    _ -> error "Internal error - block didn't become a block?"

checkProgram :: Program -> Either SemantError SProgram
checkProgram (Program binds funcs) = evalState
  (runExceptT (checkProgram' (binds, funcs)))
  baseEnv
 where
  baseEnv = Env {vars = M.empty, funcs = builtIns, thisFunc = garbageFunc}
  garbageFunc =
    Function {typ = TyVoid, name = "", formals = [], locals = [], body = []}
  checkProgram' (binds, funcs) = do
    globals <- checkBinds Global binds
    funcs'  <- mapM checkFunction funcs
    case find (\f -> sname f == "main") funcs' of
      Nothing -> throwError NoMain
      Just _  -> return (globals, funcs')
