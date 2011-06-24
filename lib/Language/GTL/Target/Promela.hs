{- Miserere mei Deus
   secundum magnam
   misericordiam tuam
 -}
{-# LANGUAGE GADTs,ScopedTypeVariables #-}
module Language.GTL.Target.Promela where

import Language.GTL.Model
import Language.GTL.Expression as GTL
import Language.Promela.Syntax as Pr
import Language.GTL.Buchi
import Language.GTL.Types
import Language.GTL.Target.Common
import Language.GTL.ErrorRefiner

import Control.Monad.Identity

import Data.Set as Set
import Data.Map as Map
import Data.List (elemIndex,genericLength)
import Data.Foldable
import Prelude hiding (foldl,concat,foldl1,mapM)
import Data.Maybe
import Data.Int

import Misc.ProgramOptions as Opts
import Misc.VerificationEnvironment

-- | Do a complete verification of a given GTL file
verifyModel :: Opts.Options -- ^ Options
               -> String -- ^ Name of the GTL file without extension
               -> GTLSpec String -- ^ The GTL file contents
               -> IO ()
verifyModel opts name spec = do
  let pr = translateSpec spec
      model = buildTargetModel spec (buildInputMap spec) (buildOutputMap spec)
  traceFiles <- runVerification opts name pr
  parseTraces opts name traceFiles (traceToAtoms model)

-- | Given a list of transitions, give a list of atoms that have to hold for each transition.
traceToAtoms :: TargetModel -- ^ The program to work on
                -> [(String,(Integer, Int))] -- ^ The transitions, given in the form (model,transition-number)
                -> Trace --[[GTLAtom (String,String)]]
traceToAtoms model trace = fmap transitionToAtoms trace
  where
    transitionToAtoms :: (String, (Integer, Int)) -> [TypedExpr (String, String)]
    transitionToAtoms (mdl, st) =
      let stateMachine = (tmodelProcs model) ! mdl
          entr = stateMachine ! st
          ats = atoms $ vars entr
      in fmap (mapGTLVars (\n -> (mdl,n))) ats

translateTarget :: TargetModel -> [Pr.Module]
translateTarget tm = var_decls ++ procs ++ init ++ ltl
  where
    var_decls = [ Pr.Decl $ Pr.Declaration Nothing (convertType tp) [(varString mdl var idx l,Nothing,case inits of
                                                                         Nothing -> Nothing
                                                                         Just dset -> Just $ translateConstant tp (unfix $ head $ Set.toList dset)
                                                                     )]
                | ((mdl,var,idx),lvl,tp,inits) <- tmodelVars tm,
                  l <- [0..lvl]
                ]
    procs = [ Pr.ProcType { proctypeActive = Nothing
                          , proctypeName = pname
                          , proctypeArguments = []
                          , proctypePriority = Nothing
                          , proctypeProvided = Nothing
                          , proctypeSteps = fmap Pr.toStep $
                                            [ prIf [[ prAtomic $ (case translateTExprs (inputConstraints $ vars st) of
                                                            Nothing -> []
                                                            Just cond -> [Pr.StmtExpr $ Pr.ExprAny cond])++
                                                        (catMaybes [ translateTRestr tvars restr
                                                                   | (tvars,restr) <- (outputConstraints $ vars st) ])++
                                                        [Pr.StmtGoto ("st_"++show s1++"_"++show s2)]
                                                      | ((s1,s2),st) <- Map.toList buchi, isStart st
                                                      ]
                                                 ]
                                            ] ++
                                            [ Pr.StmtLabel ("st_"++show s1++"_"++show s2) $
                                              prIf [[ prAtomic $ (case translateTExprs (inputConstraints $ vars nst) of
                                                           Nothing -> []
                                                           Just cond -> [Pr.StmtExpr $ Pr.ExprAny cond])++
                                                       (catMaybes [ translateTRestr tvars restr
                                                                  | (tvars,restr) <- (outputConstraints $ vars nst) ])++
                                                       [Pr.StmtGoto ("st_"++show t1++"_"++show t2)]
                                                     | (t1,t2) <- Set.toList (successors st),
                                                       let nst = buchi!(t1,t2)
                                                     ]
                                              ]
                                            | ((s1,s2),st) <- Map.toList buchi
                                            ]
                          }
            | (pname,buchi) <- Map.toList $ tmodelProcs tm ]
    init = [Pr.Init Nothing
            [Pr.toStep $ prAtomic $ [Pr.StmtSkip] ++
             {-concat [ case def of
                         Nothing -> [] -- XXX
                         Just (Fix p) -> outputTAssign [(tvar,lvl)] (translateConstant tp p)
                    | (tvar,lvl,tp,def) <- tmodelInits tm
                    ] ++-}
             [ Pr.StmtRun iname []
             | iname <- Map.keys (tmodelProcs tm)
             ]]
           ]
    ltl = [Pr.LTL Nothing (translateVerify (tmodelVerify tm))]

translateVerify :: TypedExpr TargetVar -> LTLExpr
translateVerify e = case getValue e of
  BinBoolExpr op lhs rhs -> LTLBin (case op of
                                       And -> LTLAnd
                                       Or -> LTLOr
                                       Implies -> LTLImplication
                                       Until -> LTLUntil
                                       UntilOp -> LTLUntilOp) (translateVerify (unfix lhs)) (translateVerify (unfix rhs))
  UnBoolExpr op ne -> LTLUn (case op of
                                Not -> LTLNot
                                Always -> LTLAlways
                                Next -> LTLNext
                                Finally Nothing -> LTLEventually) (translateVerify (unfix ne))
  _ -> LTLNormalExpr (translateTExpr e)

translateTExprs :: [TypedExpr TargetVar] -> Maybe Pr.AnyExpression
translateTExprs [] = Nothing
translateTExprs xs = Just $ translateTExpr $ foldl1 gtlAnd xs

translateConstant :: GTLType -> GTLValue r -> Pr.AnyExpression
translateConstant _ (GTLIntVal x) = Pr.ConstExpr $ Pr.ConstInt x
translateConstant _ (GTLByteVal x) = Pr.ConstExpr $ Pr.ConstInt (fromIntegral x)
translateConstant _ (GTLBoolVal x) = Pr.ConstExpr $ Pr.ConstBool x
translateConstant (GTLEnum xs) (GTLEnumVal x)
  = let Just i = elemIndex x xs
    in Pr.ConstExpr $ Pr.ConstInt $ fromIntegral i

translateTExpr :: TypedExpr TargetVar -> Pr.AnyExpression
translateTExpr e = case getValue e of
  Var (mdl,var,i) lvl -> Pr.RefExpr (varName mdl var i lvl)
  Value val -> translateConstant (getType e) val
  BinBoolExpr op (Fix lhs) (Fix rhs) -> let l = translateTExpr lhs
                                            r = translateTExpr rhs
                                        in case op of
                                          And -> Pr.BinExpr Pr.BinAnd l r
                                          Or -> Pr.BinExpr Pr.BinOr l r
                                          Implies -> Pr.BinExpr Pr.BinOr (Pr.UnExpr Pr.UnLNot l) r
  BinRelExpr op (Fix lhs) (Fix rhs) -> Pr.BinExpr (case op of
                                                      GTL.BinLT -> Pr.BinLT
                                                      GTL.BinLTEq -> Pr.BinLTE
                                                      GTL.BinGT -> Pr.BinGT
                                                      GTL.BinGTEq -> Pr.BinGTE
                                                      GTL.BinEq -> Pr.BinEquals
                                                      GTL.BinNEq -> Pr.BinNotEquals) (translateTExpr lhs) (translateTExpr rhs)
  BinIntExpr op (Fix lhs) (Fix rhs) -> Pr.BinExpr (case op of
                                                      OpPlus -> Pr.BinPlus
                                                      OpMinus -> Pr.BinMinus
                                                      OpMult -> Pr.BinMult
                                                      OpDiv -> Pr.BinDiv) (translateTExpr lhs) (translateTExpr rhs)
  UnBoolExpr op (Fix ne) -> Pr.UnExpr (case op of
                                          Not -> Pr.UnLNot) (translateTExpr ne)

-- | Assigns variables including changing their respective history.
outputTAssign :: [(TargetVar,Integer)] -> Pr.AnyExpression -> [Pr.Statement]
outputTAssign [] _ = []
outputTAssign (((inst,var,idx),lvl):rest) expr
  = (assign inst var idx lvl expr) ++
    (outputTAssign rest (Pr.RefExpr (varName inst var idx 0)))

-- | Does only do assignments to variables at time 0.
outputTAssignNow :: [(TargetVar,Integer)] -> Pr.AnyExpression -> [Pr.Statement]
outputTAssignNow [] _ = []
outputTAssignNow (((inst,var,idx),lvl):rest) expr
  = (assignNow inst var idx lvl expr) ++
    (outputTAssign rest (Pr.RefExpr (varName inst var idx 0)))


translateTRestr :: [(TargetVar,Integer)] -> Restriction TargetVar -> Maybe Pr.Statement
translateTRestr tvars restr
  = let checkNEquals to = case unequals restr of
          [] -> Nothing
          xs -> Just $ foldl1 (Pr.BinExpr Pr.BinAnd) (fmap (Pr.BinExpr Pr.BinNotEquals to . translateTExpr) xs)
        checkEquals to = case equals restr of
          [] -> Nothing
          xs -> Just $ foldl1 (Pr.BinExpr Pr.BinAnd) (fmap (Pr.BinExpr Pr.BinEquals to . translateTExpr) xs)
        checkAllowed to = case allowedValues restr of
          Nothing -> Nothing
          Just s -> Just $ if Set.null s
                           then Pr.ConstExpr $ Pr.ConstBool False
                           else foldl1 (Pr.BinExpr Pr.BinOr) (fmap (\i -> Pr.BinExpr Pr.BinEquals to (translateConstant (restrictionType restr) i)
                                                                   ) (Set.toList s)
                                                             )
        checkNAllowed to = if Set.null (forbiddenValues restr)
                           then Nothing
                           else Just $ foldl1 (Pr.BinExpr Pr.BinAnd) (fmap (\i -> Pr.BinExpr Pr.BinNotEquals to
                                                                                  (translateConstant (restrictionType restr) i)
                                                                           ) (Set.toList $ forbiddenValues restr))
        checkUppers to = case upperLimits restr of
          [] -> Nothing
          _ -> Just $ foldl1 (Pr.BinExpr Pr.BinAnd) (fmap (\(incl,expr) -> Pr.BinExpr (if incl
                                                                                       then Pr.BinLTE
                                                                                       else Pr.BinLT) to (translateTExpr expr))
                                                     (upperLimits restr))
        checkLowers to = case lowerLimits restr of
          [] -> Nothing
          _ -> Just $ foldl1 (Pr.BinExpr Pr.BinAnd) (fmap (\(incl,expr) -> Pr.BinExpr (if incl
                                                                                       then Pr.BinGTE
                                                                                       else Pr.BinGT) to (translateTExpr expr))
                                                     (lowerLimits restr))
        build f = foldl (\cur el -> case el of
                            Nothing -> cur
                            Just rel -> case cur of
                              Nothing -> Just rel
                              Just rcur -> Just (f rel rcur)) Nothing
    in case equals restr of
      [] -> case allowedValues restr of
        Just r -> let rr = Set.difference r (forbiddenValues restr)
                      check v = build (Pr.BinExpr Pr.BinAnd) (fmap (\f -> f (translateConstant (restrictionType restr) v)) [checkNEquals,checkUppers,checkLowers])
                  in case catMaybes [ case ((case check v of
                                                Nothing -> []
                                                Just chk -> [ Pr.StmtExpr $ Pr.ExprAny chk ])++
                                            (outputTAssign tvars (translateConstant (restrictionType restr) v))) of
                                        [] -> Nothing
                                        p -> Just p
                                    | v <- Set.toList rr ] of
                       [] -> Nothing
                       p -> Just $ prIf p
        Nothing -> case buildTGenerator (restrictionType restr)
                        (fmap (\(t,e) -> (t,translateTExpr e)) $ upperLimits restr)
                        (fmap (\(t,e) -> (t,translateTExpr e)) $ lowerLimits restr)
                        (\v -> build (Pr.BinExpr Pr.BinAnd) (fmap (\f -> f v) [checkNEquals,checkNAllowed])) tvars of
                     [] -> Nothing
                     [x] -> Just x
                     xs -> Just $ prSequence xs
      _ -> case catMaybes  [ case ((case build (Pr.BinExpr Pr.BinAnd) (fmap (\f -> f tv) [checkAllowed,checkNEquals,checkNAllowed,checkUppers,checkLowers]) of
                                       Nothing -> []
                                       Just chk -> [Pr.StmtExpr $ Pr.ExprAny chk])++
                                   (outputTAssign tvars tv)) of
                               [] -> Nothing
                               p -> Just p
                           | v <- equals restr
                           , let tv = translateTExpr v ] of
                    [] -> Nothing
                    [[p]] -> Just p
                    p -> Just $ prIf p

buildTGenerator :: GTLType -> [(Bool,Pr.AnyExpression)] -> [(Bool,Pr.AnyExpression)] -> (Pr.AnyExpression -> Maybe Pr.AnyExpression) -> [(TargetVar,Integer)] -> [Pr.Statement]
buildTGenerator tp upper lower check to
  = let rupper e = case upper of
          [] -> Pr.BinExpr Pr.BinLT e (Pr.ConstExpr $ Pr.ConstInt (case tp of
                                                                      GTLEnum xs -> (genericLength xs)-1
                                                                      GTLInt -> fromIntegral (maxBound::Int32)
                                                                      GTLBool -> 1
                                                                  ))
          _ -> foldl1 (Pr.BinExpr Pr.BinAnd) $
               fmap (\(inc,expr) -> Pr.BinExpr Pr.BinLT e (if inc
                                                           then expr
                                                           else Pr.BinExpr Pr.BinMinus expr (Pr.ConstExpr $ Pr.ConstInt 1))
                    ) upper
        rlower = fmap (\(inc,expr) -> if inc
                                      then expr
                                      else Pr.BinExpr Pr.BinPlus expr (Pr.ConstExpr $ Pr.ConstInt 1)) lower
    in case to of
      [] -> []
      ((inst,var,idx),lvl):fs
        -> let trg = Pr.RefExpr (varName inst var idx 0)
           in [minimumAssignment (Pr.ConstExpr $ Pr.ConstInt (case tp of
                                                                 GTLEnum _ -> 0
                                                                 GTLInt -> fromIntegral (minBound::Int32)
                                                                 GTLBool -> 0
                                                             )
                                 )
               (prSequence . assign inst var idx lvl)
               rlower]++
               [prDo $ [[Pr.StmtExpr $ Pr.ExprAny $ rupper trg]++
                        (outputTAssignNow to (Pr.BinExpr Pr.BinPlus trg (Pr.ConstExpr $ Pr.ConstInt 1)))
                       ]++(case check trg of
                              Nothing -> [[Pr.StmtBreak]]
                              Just rcheck -> [[Pr.StmtExpr $ Pr.ExprAny rcheck
                                              ,Pr.StmtBreak]
                                             ,[Pr.StmtElse,Pr.StmtSkip]
                                             ])
               ]


translateSpec :: GTLSpec String -> [Pr.Module]
translateSpec spec = translateTarget (buildTargetModel spec (buildInputMap spec) (buildOutputMap spec))

convertType :: GTLType -> Pr.Typename
convertType GTLInt = Pr.TypeInt
convertType GTLBool = Pr.TypeBool
convertType (GTLEnum _) = Pr.TypeInt
convertType tp = error $ "Promela target can't use type "++show tp++" yet."

varName :: String -> String -> [Integer] -> Integer -> Pr.VarRef
varName mdl var idx lvl = VarRef (varString mdl var idx lvl) Nothing Nothing

varString :: String -> String -> [Integer] -> Integer -> String
varString mdl var idx lvl = mdl ++ "_" ++ var ++ concat [ "_"++show i | i <- idx] ++ "_"++show lvl

-- | Does an assignemnt to a variable including updating its history.
assign :: String -> String -> [Integer] -> Integer -> Pr.AnyExpression -> [Pr.Statement]
assign mdl var idx lvl expr
  = foldl (\stmts cl -> Pr.StmtAssign (varName mdl var idx cl) (if cl==0
                                                                then expr
                                                                else RefExpr (varName mdl var idx (cl-1))):stmts)
    []
    [0..lvl]

-- | Does only do an assignment for the actual moment
assignNow :: String -> String -> [Integer] -> Integer -> Pr.AnyExpression -> [Pr.Statement]
assignNow mdl var idx lvl expr
  = [Pr.StmtAssign (varName mdl var idx 0) expr]

minimumAssignment :: Pr.AnyExpression -> (Pr.AnyExpression -> Pr.Statement) -> [Pr.AnyExpression] -> Pr.Statement
minimumAssignment def f []     = f def
minimumAssignment _   f (x:xs) = minimumAssignment' x xs
  where
    minimumAssignment' x [] = f x
    minimumAssignment' x (y:ys) = prIf [ [Pr.StmtExpr $ Pr.ExprAny $ Pr.BinExpr Pr.BinLT x y
                                         ,minimumAssignment' x ys
                                         ]
                                       , [Pr.StmtElse
                                         ,minimumAssignment' y ys
                                         ]
                                       ]
