{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}

module SplTypeChecker where

import SplAST

import Prelude
import Control.Monad.State
import Control.Monad.Except
import Data.List (nub)
import qualified Data.Map as Map
import qualified Data.Set as Set

-- Leans strongly on http://dev.stephendiehl.com/fun/006_hindley_milner.html

type Name = String

newtype TVar = TV String
    deriving (Show, Eq, Ord)

data SplSimpleTypeR = SplTypeConst SplBasicType
                    | SplTypeTupleR SplSimpleTypeR SplSimpleTypeR
                    | SplTypeListR SplSimpleTypeR
                    | SplTypeVar TVar
                    | SplVoid
        deriving (Show, Eq)

data SplTypeR = SplSimple SplSimpleTypeR
              | SplTypeFunction [SplSimpleTypeR] SplSimpleTypeR
        deriving (Show, Eq)

data Scheme = Forall [TVar] SplTypeR
    deriving (Show, Eq)

data TypeKind
    = TPV -- TypePlaceholderVariable: like a in "a fiets = 1;"
    | Var -- Variable or function names
    deriving (Eq, Show, Ord)

-- a map from names to schemes
newtype TypeEnv = TypeEnv (Map.Map (TypeKind, Name) Scheme)
    deriving (Monoid, Show)

data TypeError
    = UnificationFail SplTypeR SplTypeR
    | UnificationFail3 SplTypeR SplTypeR SplTypeR
    | InfiniteType TVar SplTypeR
    | ConflictingDeclaration Name
    | UnboundVariable Name
    | UnexpectedFunction SplTypeR
    | UnexpectedVoid
    deriving (Show, Eq)

data SplEnv = SplEnv { nextFreshVar :: Int, typeEnv :: TypeEnv, returnBlocks :: [Bool], returnType :: SplSimpleTypeR }
    deriving Show

type Infer a = ExceptT TypeError (State SplEnv) a
type Subst = Map.Map TVar SplTypeR


runInfer :: Infer (Subst, SplTypeR) -> Either TypeError Scheme
runInfer m = case evalState (runExceptT m) initEnv of
    Left err -> Left err
    Right res -> Right $ closeOver res

--execInfer :: Infer (Subst, SplTypeR) -> Either TypeError SplEnv
execInfer :: Infer (Subst, SplTypeR) -> SplEnv
execInfer m = execState (runExceptT m) initEnv

closeOver :: (Map.Map TVar SplTypeR, SplTypeR) -> Scheme
closeOver (sub, ty) = normalize sc
    where sc = generalize emptyTypeEnv (apply sub ty)

normalize :: Scheme -> Scheme
normalize (Forall _ body) = Forall (fmap snd ord) (normtype body)
    where
        ord = zip (nub $ fv body) (fmap TV letters)

        fv (SplSimple (SplTypeVar a)) = [a]
        fv (SplSimple (SplTypeListR a)) = fv (SplSimple a)
        fv (SplSimple (SplTypeTupleR l r)) = fv (SplSimple l) ++ fv (SplSimple r)
        fv (SplTypeFunction argTypes retType) = concatMap (fv . SplSimple) argTypes ++ fv (SplSimple retType)
        fv _ = []

        normtype :: SplTypeR -> SplTypeR
        normtype (SplTypeFunction argTypes retType) = SplTypeFunction (map normtypeS argTypes)  (normtypeS retType)
        normtype (SplSimple t) = SplSimple $ normtypeS t

        normtypeS :: SplSimpleTypeR -> SplSimpleTypeR
        normtypeS a@(SplTypeConst _) = a
        normtypeS (SplTypeTupleR a b) = SplTypeTupleR (normtypeS a) (normtypeS b)
        normtypeS (SplTypeListR a) = SplTypeListR (normtypeS a)
        normtypeS SplVoid = SplVoid
        normtypeS (SplTypeVar a) =
            case lookup a ord of
                Just x -> SplTypeVar x
                Nothing -> error "type variable not in signature"


nullSubst :: Subst
nullSubst = Map.empty

emptyTypeEnv :: TypeEnv
emptyTypeEnv = TypeEnv $ Map.fromList [((Var, "isEmpty"), Forall [TV "isEmptyVar"]
                                            (SplTypeFunction [SplTypeListR $ SplTypeVar $ TV "isEmptyVar"]
                                                (SplTypeConst SplBool)
                                            )
                                        ),
                                       ((Var, "print"), Forall []
                                            (SplTypeFunction [SplTypeConst SplChar] SplVoid)
                                       ),
                                       ((Var, "printInt"), Forall []
                                            (SplTypeFunction [SplTypeConst SplInt] SplVoid)
                                       )
                                       ]

initEnv :: SplEnv
initEnv = SplEnv {nextFreshVar = 0, typeEnv = emptyTypeEnv, returnBlocks = [], returnType = undefined}

compose :: Subst -> Subst -> Subst
s1 `compose` s2 = Map.map (apply s1) s2 `Map.union` s1

extend :: ((TypeKind, Name), Scheme) -> SplEnv -> SplEnv
extend (x, scheme) s@(SplEnv {typeEnv=TypeEnv env}) = s{typeEnv = TypeEnv $ Map.insert x scheme env}

class Substitutable a where
    apply :: Subst -> a -> a
    ftv :: a -> Set.Set TVar

instance Substitutable SplTypeR where
    apply s (SplSimple t) = SplSimple $ apply s t
    apply s (SplTypeFunction argTypes retType) = SplTypeFunction (apply s argTypes) (apply s retType)

    ftv (SplTypeFunction argTypes retType) = ftv argTypes `Set.union` ftv retType
    ftv (SplSimple t) = ftv t

instance Substitutable SplSimpleTypeR where
    apply _ t@(SplTypeConst _) = t
    apply s (SplTypeTupleR l r) = SplTypeTupleR (apply s l) (apply s r)
    apply s (SplTypeListR t) = SplTypeListR (apply s t)
    apply s t@(SplTypeVar a) = do
        case Map.findWithDefault (SplSimple t) a s of
            SplSimple r -> r
            _ -> t
    apply _ SplVoid = SplVoid

    ftv SplVoid = Set.empty
    ftv (SplTypeConst _) = Set.empty
    ftv (SplTypeTupleR l r) = ftv l `Set.union` ftv r
    ftv (SplTypeListR t) = ftv t
    ftv (SplTypeVar a) = Set.singleton a

instance Substitutable Scheme where
    apply s (Forall as t) = Forall as $ apply s' t
        where s' = foldr Map.delete s as
    ftv (Forall as t) = ftv t `Set.difference` Set.fromList as

instance Substitutable a => Substitutable [a] where
    apply = fmap . apply
    ftv = foldr (Set.union . ftv) Set.empty

instance Substitutable TypeEnv where
    apply s (TypeEnv env) = TypeEnv $ Map.map (apply s) env
    ftv (TypeEnv env) = ftv $ Map.elems env

instance Substitutable SplEnv where
    apply sub env = env{typeEnv = apply sub $ typeEnv env}
    ftv env = ftv $ typeEnv env

-- ["α", "β", ..., "ω", "αα", ... ]
letters :: [String]
letters = [1..] >>= flip replicateM ['α' .. 'ω']

-- Get fresh type vars
fresh :: Infer SplSimpleTypeR
fresh = do
    s <- get
    put s{nextFreshVar = nextFreshVar s + 1}
    return $ SplTypeVar $ TV (letters !! nextFreshVar s)

-- Check if a type variable exists before we try to replace it
occursCheck :: Substitutable a => TVar -> a -> Bool
occursCheck a t = a `Set.member` ftv t

-- unify
class Unify a where
    unify :: a -> a -> Infer Subst


instance Unify SplTypeR where
    unify (SplSimple t) (SplSimple t') = unify t t'
    unify (SplTypeFunction argTypes retType) (SplTypeFunction argTypes' retType') = do
        s1 <- recApply nullSubst argTypes argTypes'
        s2 <- unify (apply s1 retType) (apply s1 retType')
        return (s2 `compose` s1)
        where
            recApply _ [] [] = return nullSubst
            recApply s [x] [y] = do
                s1 <- unify x y
                return (s1 `compose` s)
            recApply s (x:x':xs) (y:y':ys) = do
                s1 <- unify x y
                recApply (s1 `compose` s) ((apply s1 x'):xs) ((apply s1 y'):ys)
            recApply _ _ _ = fail "Function call with the wrong number of arguments"

    unify t1 t2 = throwError $ UnificationFail t1 t2


instance Unify SplSimpleTypeR where
    unify (SplTypeConst a) (SplTypeConst b) | a == b = return nullSubst
    unify SplVoid SplVoid = return nullSubst
    unify (SplTypeVar a) t = bind a t
    unify t (SplTypeVar a) = bind a t
    unify (SplTypeTupleR l r) (SplTypeTupleR l' r') = do
        s1 <- unify l l'
        s2 <- unify (apply s1 r) (apply s1 r')
        return (s2 `compose` s1)
    unify (SplTypeListR a) (SplTypeListR b) = unify a b
    unify t1 t2 = throwError $ UnificationFail (SplSimple t1) (SplSimple t2)

bind :: TVar -> SplSimpleTypeR -> Infer Subst
bind a t
  | t == SplTypeVar a = return nullSubst
  | occursCheck a t = throwError $ InfiniteType a (SplSimple t)
  | otherwise = return $ Map.singleton a (SplSimple t)

instantiate :: Scheme -> Infer SplTypeR
instantiate (Forall as t) = do
    as' <- mapM (const fresh) as
    let s = (Map.fromList $ zip as (map SplSimple as')) :: Subst
    return $ apply s t

generalize :: TypeEnv -> SplTypeR -> Scheme
generalize env t = Forall as t
    where as = Set.toList $ ftv t `Set.difference` ftv env

returnSimple :: (Monad m) => Subst -> SplSimpleTypeR -> m (Subst, SplTypeR)
returnSimple s x = return (s, SplSimple x)

unsimple :: MonadError TypeError m => (s1, SplTypeR) -> m (s1, SplSimpleTypeR)
unsimple (s1, SplSimple s) = return (s1, s)
unsimple (_, t) = throwError $ UnexpectedFunction t

class Inferer a where
    infer :: a -> Infer (Subst, SplTypeR)

lookupEnv :: (TypeKind, Name) -> Infer (Subst, SplTypeR)
lookupEnv x = do
  (TypeEnv env) <- gets typeEnv
  case Map.lookup x env of
    Nothing -> throwError $ UnboundVariable (show x)
    Just s  -> do t <- instantiate s
                  return (nullSubst, t)

instance Inferer Spl where
    infer (Spl l) = do
        mapM_ infer l
        returnSimple nullSubst SplVoid


instance Inferer SplDecl where
    infer (SplDeclVar d) = infer d
    infer (SplDeclFun name argNames argTypes retType varDecls stmts) = do
        -- check if name exists
        (TypeEnv env) <- gets typeEnv
        let funExists = Map.member (Var, name) env
        when (funExists) (throwError $ ConflictingDeclaration name)

        nameTypes <- if (null argTypes)
            then do
                argTypes' <- replicateM (length argNames) fresh
                return $ zip argNames argTypes'
            else do
                -- we argue that substitutions on types in the function params don't matter at this point
                argTypes' <- mapM (\x -> infer x >>= unsimple >>= \(_, y) -> return y) argTypes
                return $ zip argNames argTypes'

        -- set up expected return value
        (_, retType') <- infer retType >>= unsimple

        -- insert function declaration into state
        let argTypes' = snd $ unzip nameTypes
        let resultType = SplTypeFunction argTypes' retType'
        modify $ extend ((Var, name), Forall (Set.toList $ ftv argTypes') resultType)

        -- copy state for scope resolution
        globalState <- get

        -- Assign arguments with their types
        -- insert all arguments into the local environment
        -- fixme check if forall t -> t is needed
        let (TypeEnv env') = typeEnv globalState
        let localEnv = foldr (\(n, t) -> Map.insert (Var, n) (Forall [] (SplSimple t))) env' nameTypes

        -- prepare local env, push false on return stack, set expected return type
        let localState = globalState{typeEnv = TypeEnv localEnv, returnBlocks = [], returnType = retType' }
        put localState

        -- check var decls
        -- note that substitutions are applied by varDecl's infer, if that changes: fix
        subVars <- mapM infer varDecls >>= \list -> return $ foldl (\s2 (s, _)-> s `compose` s2) nullSubst list

        -- check stmts
        -- fixme what to do about s
        (s, _) <- infer stmts

        -- pop bool from return stack, if False, check if retType is Void
        [hasReturn] <- gets returnBlocks
        _ <- if (not hasReturn)
            then unify SplVoid retType'
            else return nullSubst


        -- reset scoping from copied state
        put globalState

        -- apply substitutions
        modify $ apply (s `compose` subVars)


        -- return type
        return ((s `compose` subVars), resultType)


instance Inferer SplType where
    infer (SplType a) = returnSimple nullSubst (SplTypeConst a)
    infer (SplTypeList a) = do
        (s1, t1) <- infer a >>= unsimple
        returnSimple s1 (SplTypeListR t1)
    infer (SplTypeTuple l r) = do
        (s1, t1) <- infer l >>= unsimple
        modify (apply s1)
        (s2, t2) <- infer r >>= unsimple
        returnSimple (s2 `compose` s1) (SplTypeTupleR t1 t2)
    infer (SplTypeUnknown) = do
        var <- fresh
        returnSimple nullSubst var
    infer (SplTypePlaceholder str) = do
        (TypeEnv env) <- gets typeEnv
        case Map.lookup (TPV, str) env of
            Nothing -> do
                n <- SplSimple <$> fresh
                modify (extend ((TPV, str), Forall [] n))
                return (nullSubst, n)
            Just (Forall _ t) -> return (nullSubst, t)


instance Inferer SplRetType where
    infer (SplRetType t) = infer t
    infer SplRetVoid = returnSimple nullSubst SplVoid


instance Inferer SplVarDecl where
    -- <type> <name> = <expr>;
    infer (SplVarDecl t name expr) = do
        (TypeEnv env) <- gets typeEnv
        let varExists = Map.member (Var, name) env
        when varExists
            (throwError $ ConflictingDeclaration name)
        -- get declared type
        (_, t') <- infer t >>= unsimple
        (s1, et) <- infer expr >>= unsimple
        modify $ apply s1  -- update env
        s2 <- unify t' et
        modify $ apply s2
        --do something
        modify $ extend ((Var, name), apply s2 (Forall [] $ SplSimple t'))

        returnSimple (s2 `compose` s1) SplVoid


instance Inferer SplExpr where
    infer (SplIdentifierExpr name field) = do
        (s, t) <- lookupEnv (Var, name) >>= unsimple
        (_, tf) <- inferField (apply s t) field
        returnSimple s tf

    infer (SplUnaryExpr op expr) = do
        (s, e1) <- infer expr >>= unsimple
        modify $ apply s
        case op of
            SplOperatorInvert -> do
                s' <- unify e1 (SplTypeConst SplBool)
                returnSimple (s' `compose` s) (apply s' e1)
            SplOperatorNegate -> do
                s' <- unify e1 (SplTypeConst SplInt)
                returnSimple (s' `compose` s) (apply s' e1)

    infer (SplBinaryExpr op l r) = do
        case op of
            SplOperatorAdd -> (binaryOp SplInt SplInt) `catchError` (catchBinaryCharOp SplChar)
            SplOperatorSubtract -> (binaryOp SplInt SplInt) `catchError` (catchBinaryCharOp SplChar)
            SplOperatorMultiply -> binaryOp SplInt SplInt
            SplOperatorDivide -> binaryOp SplInt SplInt
            SplOperatorModulus -> binaryOp SplInt SplInt
            SplOperatorLess -> binaryOp SplInt SplBool `catchError` (catchBinaryCharOp SplBool)
            SplOperatorLessEqual -> binaryOp SplInt SplBool `catchError` (catchBinaryCharOp SplBool)
            SplOperatorEqual -> binarySameArgTypeToBool
            SplOperatorGreaterEqual -> binaryOp SplInt SplBool `catchError` (catchBinaryCharOp SplBool)
            SplOperatorGreater -> binaryOp SplInt SplBool `catchError` (catchBinaryCharOp SplBool)
            SplOperatorNotEqual -> binarySameArgTypeToBool
            SplOperatorAnd -> binaryOp SplBool SplBool
            SplOperatorOr -> binaryOp SplBool SplBool
            SplOperatorCons -> do
                (sl, tl) <- infer l >>= unsimple
                (sr, tr) <- infer r >>= unsimple
                s <- unify (apply sr (SplTypeListR tl)) (apply sl tr)
                returnSimple (s `compose` sr `compose` sl) $ (apply (s `compose` sl) tr)
        where
            binarySameArgTypeToBool = do
                (sl, tl) <- infer l >>= unsimple
                (sr, tr) <- infer r >>= unsimple
                s <- unify (apply sr tl) (apply sl tr)
                returnSimple (s `compose` sr `compose` sl) $ SplTypeConst SplBool

            binaryOp argType retType = do
                (sl, tl) <- infer l >>= unsimple
                (sr, tr) <- infer r >>= unsimple
                sl' <- unify (SplTypeConst argType) tl
                sr' <- unify (SplTypeConst argType) tr
                returnSimple (sr' `compose` sl' `compose` sr `compose` sl) $ SplTypeConst retType

            catchBinaryCharOp retType (UnificationFail _ c) = do
                (sl, tl) <- infer l >>= unsimple
                (sr, tr) <- infer r >>= unsimple
                sl' <- (unify tl $ SplTypeConst SplChar) `catchError` catchCharUnify c
                sr' <- (unify tr $ SplTypeConst SplChar) `catchError` catchCharUnify c
                returnSimple (sr' `compose` sl' `compose` sr `compose` sl) $ SplTypeConst retType
            catchBinaryCharOp _ e = throwError e

            catchCharUnify c (UnificationFail a b) = throwError $ UnificationFail3 a b c
            catchCharUnify _ e = throwError e

    infer (SplIntLiteralExpr _) = returnSimple nullSubst (SplTypeConst SplInt)
    infer (SplCharLiteralExpr _) = returnSimple nullSubst (SplTypeConst SplChar)
    infer (SplBooleanLiteralExpr _) = returnSimple nullSubst (SplTypeConst SplBool)

    infer (SplEmptyListExpr) = do
        n <- fresh
        returnSimple nullSubst n

    infer (SplTupleExpr l r) = do
        (sl, tl) <- infer l >>= unsimple
        modify $ apply sl
        (sr, tr) <- infer r >>= unsimple
        returnSimple (sr `compose` sl) (SplTypeTupleR tl tr)

    infer (SplFuncCallExpr name args) = do
        (_, tn) <- lookupEnv (Var, name)
        (sargs, targs) <- inferArguments args
        ret <- fresh
        s <- unify (apply sargs tn) (SplTypeFunction targs ret)

        let retType = apply s ret
        returnSimple (s `compose` sargs) retType

instance Inferer [SplStmt] where
    infer stmts = do
        -- push False for the return of this Block.
        -- Any return statements in the block will change the value to True
        env <- get
        put $ env{returnBlocks = (False : returnBlocks env)}

        inferStmts stmts
        where
            inferStmts :: [SplStmt] -> Infer (Subst, SplTypeR)
            inferStmts [] = returnSimple nullSubst SplVoid
            inferStmts (x:xs) = do
                (st, _) <- infer x
                modify $ apply st
                (sr, _) <- inferStmts xs
                returnSimple (st `compose` sr) SplVoid


instance Inferer SplStmt where
    infer (SplIfStmt cond thenStmts elseStmts) = do
        -- condition
        (sc, tc) <- infer cond >>= unsimple
        modify $ apply sc
        s1 <- unify tc (SplTypeConst SplBool)
        modify $ apply s1

        -- then
        (st, _) <- infer thenStmts >>= unsimple
        modify $ apply st

        -- else
        (se, te) <- infer elseStmts >>= unsimple
        rets <- gets returnBlocks
        let (elseHasReturn : thenHasReturn : curBlockHasReturn : restReturns) = rets

        -- update environment
        let curBlockHasReturn' = curBlockHasReturn || thenHasReturn && elseHasReturn
        env <- get
        put env{returnBlocks = (curBlockHasReturn' : restReturns)}

        returnSimple (st `compose` se `compose` s1 `compose` sc) te

    infer (SplWhileStmt cond stmts) = do
        (sc, tc) <- infer cond >>= unsimple
        modify $ apply sc
        s1 <- unify tc (SplTypeConst SplBool)
        modify $ apply s1
        (st, tt) <- infer stmts >>= unsimple

        -- update return state: drop return from while because it may not be executed
        (_, restReturns) <- gets ((splitAt 1) . returnBlocks)
        env <- get
        put $ env{returnBlocks = restReturns}

        returnSimple (st `compose` s1 `compose` sc) tt

    infer (SplAssignmentStmt name field expr) = do
        (se, te) <- infer expr >>= unsimple
        modify $ apply se
        (sn, tn) <- lookupEnv (Var, name) >>= unsimple
        (_, tf) <- inferField (apply sn tn) field
        st <- unify (apply sn te) tf
        returnSimple (st `compose` sn `compose` se) tf

{-
    infer (SplFuncCallStmt "print" [arg]) = do
        (sarg, targ) <- infer arg
        s <- unify (SplTypeConst SplInt) targ -- `catchError` handlePrint
        error "not yet implemented
-}

    infer (SplFuncCallStmt name args) = do
        (_, tn) <- lookupEnv (Var, name)
        (sargs, targs) <- inferArguments args
        ret <- fresh
        s <- unify (apply sargs tn) (SplTypeFunction targs ret)

        let retType = apply s ret
        -- todo: Warning if not result is discarded, as this is a stmt
        returnSimple (s `compose` sargs) retType

    -- todo unify
    infer (SplReturnStmt expr) = do
        env <- get
        let (_, restReturns) = ((splitAt 1) . returnBlocks) env

        -- infer expression and apply subst to state
        (s, t) <- infer expr >>= unsimple
        modify $ apply s

        -- unify return type with expected return type
        let retType = apply s $ returnType env
        s' <- unify t retType
        let retType' = apply s' retType

        -- update state
        put $ env{returnType = retType', returnBlocks = (True : restReturns)}

        returnSimple (s' `compose` s) retType'


    infer SplReturnVoidStmt = do
        env <- get
        let (_, restReturns) = ((splitAt 1) . returnBlocks) env

        -- unify return type with expected return type
        let retType = returnType env
        s <- unify SplVoid retType
        let retType' = apply s retType

        -- update state
        put $ env{returnType = retType', returnBlocks = (True : restReturns)}

        returnSimple s SplVoid


inferArguments :: (Inferer a) => [a] -> Infer (Subst, [SplSimpleTypeR])
inferArguments [] = return (nullSubst, [])
inferArguments (x:xs) = do
    (s, t) <- infer x >>= unsimple
    (s', t') <- inferArguments xs
    return ((s' `compose` s), t : t')


inferField :: SplSimpleTypeR -> SplField -> Infer (Subst, SplSimpleTypeR)
inferField parentType SplFieldNone = return (nullSubst, parentType)
inferField parentType (SplFieldHd f) = do
    n <- fresh
    s <- unify (SplTypeListR n) parentType
    modify $ apply s
    inferField (apply s n) f

inferField parentType (SplFieldTl f) = do
    n <- fresh
    s <- unify (SplTypeListR n) parentType
    modify $ apply s
    inferField (apply s parentType) f

inferField parentType (SplFieldFst f) = do
    n <- fresh
    m <- fresh
    s <- unify (SplTypeTupleR n m) parentType
    modify $ apply s
    inferField (apply s n) f

inferField parentType (SplFieldSnd f) = do
    n <- fresh
    m <- fresh
    s <- unify (SplTypeTupleR n m) parentType
    modify $ apply s
    inferField (apply s m) f
