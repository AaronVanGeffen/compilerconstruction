module SplIR where

import Prelude
import SplAST
import Control.Monad.State

type SplIR = [SplInstruction]

data SplPseudoRegister
    -- simple register
    = Reg String
    -- pointers left, right
    | Tuple SplPseudoRegister SplPseudoRegister
    -- list value and pointer to tail
    | List SplPseudoRegister SplPseudoRegister
    -- for tail empty
    | EmptyList
    deriving (Show, Eq)

type SplLabel = String

data SplImm = SplImmInt Integer | SplImmBool Bool | SplImmChar Char
    deriving Show

data SplInstruction
    = SplFunction SplLabel [SplPseudoRegister] SplIR
    | SplBinaryOperation SplBinaryOperator SplPseudoRegister SplPseudoRegister SplPseudoRegister
    | SplUnaryOperation SplUnaryOperator SplPseudoRegister SplPseudoRegister
    | SplJumpTarget SplLabel
    | SplRet SplPseudoRegister
    | SplJump SplLabel
    | SplJumpIf SplPseudoRegister SplLabel
    | SplJumpIfNot SplPseudoRegister SplLabel
    | SplMov SplPseudoRegister SplPseudoRegister
    | SplMovImm SplPseudoRegister SplImm
    | SplCall SplLabel [SplPseudoRegister]
    deriving (Show)


data Env = Env {
        nextVar :: Int,
        nextLabel :: Int
    }

type IRState = State Env


getNextVar :: IRState SplPseudoRegister
getNextVar = do
    s <- get
    let i = nextVar s
    put s{nextVar = 1 + (nextVar s)}
    return $ Reg $ "t" ++ show i

getNextLabel :: String -> IRState String
getNextLabel prefix = do
    s <- get
    let i = nextLabel s
    put s{nextLabel = 1 + (nextLabel s)}
    return $ prefix ++ show i

exprToIR :: SplExpr -> IRState (SplIR, SplPseudoRegister)
exprToIR (SplIdentifierExpr name SplFieldNone) = return ([], Reg name)
exprToIR (SplBinaryExpr op e1 e2) = do
    (e1IR, e1ResultRegister) <- exprToIR e1
    (e2IR, e2ResultRegister) <- exprToIR e2
    resultRegister <- getNextVar
    return ((e1IR ++ e2IR ++
                [SplBinaryOperation op resultRegister e1ResultRegister e2ResultRegister]),
            resultRegister)
exprToIR (SplUnaryExpr op e1) = do
    (e1IR, e1ResultRegister) <- exprToIR e1
    resultRegister <- getNextVar
    return ((e1IR ++
                [SplUnaryOperation op resultRegister e1ResultRegister]),
            resultRegister)
exprToIR (SplIntLiteralExpr i) = do
    resultRegister <- getNextVar
    return ([SplMovImm resultRegister (SplImmInt i)], resultRegister)
exprToIR (SplCharLiteralExpr i) = do
    resultRegister <- getNextVar
    return ([SplMovImm resultRegister (SplImmChar i)], resultRegister)
exprToIR (SplBooleanLiteralExpr i) = do
    resultRegister <- getNextVar
    return ([SplMovImm resultRegister (SplImmBool i)], resultRegister)
exprToIR (SplFuncCallExpr name args) = do
    argIRsResultRegs <- mapM exprToIR args
    let (argIRs, resultRegs) = unzip argIRsResultRegs
    resultRegister <- getNextVar
    return (concat argIRs ++ [SplCall name resultRegs], resultRegister)


replaceName :: SplPseudoRegister -> SplPseudoRegister -> SplInstruction -> SplInstruction
replaceName from to instruction = case instruction of
    (SplCall label args) -> SplCall label $ map replace args
    (SplBinaryOperation op target a b) -> SplBinaryOperation op (replace target) (replace a) (replace b)
    (SplUnaryOperation op target a) -> SplUnaryOperation op (replace target) (replace a)
    (SplRet r) -> SplRet (replace r)
    (SplFunction label args ir) -> SplFunction label (map replace args) ir
    (SplJumpIf r label) -> SplJumpIf (replace r) label
    (SplJumpIfNot r label) -> SplJumpIfNot (replace r) label
    (SplMov r r2) -> SplMov (replace r) (replace r2)
    (SplMovImm r i) -> SplMovImm (replace r) i
    SplJumpTarget t -> SplJumpTarget t
    SplJump t -> SplJump t
    where
    replace x = if (x == from) then to else x

toIR :: SplStmt -> IRState SplIR
toIR (SplWhileStmt cond loop) = do
    (condIR, compareRegister) <- exprToIR cond
    label <- getNextLabel "while"
    let labelAfter = label ++ "end"
    loopIR <- mapM toIR loop
    return $ (SplJumpTarget label : condIR) ++
            (SplJumpIfNot compareRegister labelAfter : (concat loopIR) ++ [SplJump label])

toIR (SplIfStmt cond thenStmts elseStmts) = do
    (condIR, compareRegister) <- exprToIR cond
    elseLabel <- getNextLabel "else"
    let elseAfterLabel = elseLabel ++ "end"
    thenIR <- mapM toIR thenStmts
    elseIR <- mapM toIR elseStmts
    return $ condIR ++ (SplJumpIfNot compareRegister elseLabel : (concat thenIR ++ [SplJump elseAfterLabel]))
        ++ (SplJumpTarget elseLabel : concat elseIR) ++ [SplJumpTarget elseAfterLabel]

toIR (SplAssignmentStmt name SplFieldNone expr) = do
    (condIR, resultRegister) <- exprToIR expr
    let condIR' = map (replaceName resultRegister (Reg name)) condIR
    return condIR'

toIR (SplFuncCallStmt name args) = do
    argIRsResultRegs <- mapM exprToIR args
    let (argIRs, resultRegs) = unzip argIRsResultRegs
    return (concat argIRs ++ [SplCall name resultRegs])