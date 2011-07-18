{-# LANGUAGE TypeFamilies,GADTs #-}
module Language.GTL.Backend.Scade where

import Language.Scade.Lexer (alexScanTokens)
import Language.Scade.Parser (scade)
import Language.GTL.Backend
import Language.GTL.Translation
import Language.GTL.Types
import Language.Scade.Syntax as Sc
import Language.Scade.Pretty
import Language.GTL.Expression as GTL
import Language.GTL.LTL as LTL
import Language.GTL.Buchi
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Control.Monad.Identity

data Scade = Scade deriving (Show)

instance GTLBackend Scade where
  data GTLBackendModel Scade = ScadeData String [Sc.Declaration] ScadeTypeMapping
  backendName Scade = "scade"
  initBackend Scade [file,name] = do
    str <- readFile file
    let decls = scade $ alexScanTokens str
    return $ ScadeData name decls (scadeTypes decls)
  typeCheckInterface Scade (ScadeData name decls tps) (ins,outs) = do
    let (sc_ins,sc_outs) = scadeInterface (scadeParseNodeName name) decls
        Just local = scadeMakeLocal (scadeParseNodeName name) tps
    mp_ins <- scadeTypeMap tps local sc_ins
    mp_outs <- scadeTypeMap tps local sc_outs
    rins <- mergeTypes ins mp_ins
    routs <- mergeTypes outs mp_outs
    return (rins,routs)
  cInterface Scade (ScadeData name decls tps)
    = let (inp,outp) = scadeInterface (scadeParseNodeName name) decls
      in CInterface { cIFaceIncludes = [name++".h"]
                    , cIFaceStateType = ["outC_"++name]
                    , cIFaceInputType = if Prelude.null inp
                                        then []
                                        else ["inC_"++name]
                    , cIFaceStateInit = \[st] -> name++"_reset(&("++st++"))"
                    , cIFaceIterate = \[st] inp -> case inp of
                         [] -> name++"(&("++st++"))"
                         [rinp] -> name++"(&("++rinp++"),&("++st++"))"
                    , cIFaceGetInputVar = \[inp] var -> inp++"."++var
                    , cIFaceGetOutputVar = \[st] var -> st++"."++var
                    , cIFaceTranslateType = scadeTranslateTypeC
                    , cIFaceTranslateValue = scadeTranslateValueC
                    }
  backendVerify Scade (ScadeData name decls tps) expr 
    = let (inp,outp) = scadeInterface (scadeParseNodeName name) decls
          scade = buchiToScade name (Map.fromList inp) (Map.fromList outp) (gtl2ba expr)
      in do
        print $ prettyScade [scade]
        return $ Nothing

scadeTranslateTypeC :: GTLType -> String
scadeTranslateTypeC GTLInt = "kcg_int"
scadeTranslateTypeC GTLBool = "kcg_bool"
scadeTranslateTypeC rep = error $ "Couldn't translate "++show rep++" to C-type"

scadeTranslateValueC :: GTLConstant -> String
scadeTranslateValueC d = case unfix d of
  GTLIntVal v -> show v
  GTLBoolVal v -> if v then "1" else "0"
  _ -> error $ "Couldn't translate "++show d++" to C-value"

scadeTypeToGTL :: ScadeTypeMapping -> ScadeTypeMapping -> Sc.TypeExpr -> Maybe GTLType
scadeTypeToGTL _ _ Sc.TypeInt = Just GTLInt
scadeTypeToGTL _ _ Sc.TypeBool = Just GTLBool
scadeTypeToGTL _ _ Sc.TypeReal = Just GTLFloat
scadeTypeToGTL _ _ Sc.TypeChar = Just GTLByte
scadeTypeToGTL g l (Sc.TypePath (Path path)) = do
  tp <- scadeLookupType g l path
  scadeTypeToGTL g Map.empty tp
scadeTypeToGTL g l (Sc.TypeEnum enums) = Just (GTLEnum enums)
scadeTypeToGTL g l (Sc.TypePower tp expr) = do
  rtp <- scadeTypeToGTL g l tp
  case expr of
    ConstIntExpr 1 -> return rtp
    ConstIntExpr n -> return (GTLArray n rtp)
scadeTypeToGTL _ _ _ = Nothing

data ScadeTypeInfo = ScadePackage ScadeTypeMapping
                   | ScadeType Sc.TypeExpr
                   deriving Show

type ScadeTypeMapping = Map String ScadeTypeInfo

scadeLookupType :: ScadeTypeMapping -> ScadeTypeMapping -> [String] -> Maybe Sc.TypeExpr
scadeLookupType global local name = case scadeLookupType' local name of
  Nothing -> scadeLookupType' global name
  Just res -> Just res
  where
    scadeLookupType' mp [] = Nothing
    scadeLookupType' mp (n:ns) = do
      res <- Map.lookup n mp
      case res of
        ScadeType expr -> case ns of
          [] -> Just expr
          _ -> Nothing
        ScadePackage nmp -> scadeLookupType' nmp ns

scadeMakeLocal :: [String] -> ScadeTypeMapping -> Maybe ScadeTypeMapping
scadeMakeLocal [_] mp = Just mp
scadeMakeLocal (x:xs) mp = do
  entr <- Map.lookup x mp
  case entr of
    ScadePackage nmp -> scadeMakeLocal xs nmp
    ScadeType _ -> Nothing

scadeTypes :: [Sc.Declaration] -> ScadeTypeMapping
scadeTypes [] = Map.empty
scadeTypes ((TypeBlock tps):xs) = foldl (\mp (TypeDecl _ name cont) -> case cont of
                                            Nothing -> mp
                                            Just expr -> Map.insert name (ScadeType expr) mp
                                        ) (scadeTypes xs) tps
scadeTypes ((PackageDecl _ name decls):xs) = Map.insert name (ScadePackage (scadeTypes decls)) (scadeTypes xs)
scadeTypes (_:xs) = scadeTypes xs

scadeTypeMap :: ScadeTypeMapping -> ScadeTypeMapping -> [(String,Sc.TypeExpr)] -> Either String (Map String GTLType)
scadeTypeMap global local tps = do
  res <- mapM (\(name,expr) -> case scadeTypeToGTL global local expr of
                  Nothing -> Left $ "Couldn't convert SCADE type "++show expr++" to GTL"
                  Just tp -> Right (name,tp)) tps
  return $ Map.fromList res

scadeParseNodeName :: String -> [String]
scadeParseNodeName name = case break (=='.') name of
  (rname,[]) -> [rname]
  (name1,rest) -> name1:(scadeParseNodeName (tail rest))

-- | Extract type information from a SCADE model.
--   Returns two list of variable-type pairs, one for the input variables, one for the outputs.
scadeInterface :: [String] -- ^ The name of the Scade model to analyze
                  -> [Sc.Declaration] -- ^ The parsed source code
                  -> ([(String,Sc.TypeExpr)],[(String,Sc.TypeExpr)])
scadeInterface (name@(n1:names)) ((Sc.PackageDecl _ pname decls):xs)
  | n1==pname = scadeInterface names decls
  | otherwise = scadeInterface name xs
scadeInterface [name] (op@(Sc.UserOpDecl {}):xs)
  | Sc.userOpName op == name = (varNames' (Sc.userOpParams op),varNames' (Sc.userOpReturns op))
  | otherwise = scadeInterface [name] xs
    where
      varNames' :: [Sc.VarDecl] -> [(String,Sc.TypeExpr)]
      varNames' (x:xs) = (fmap (\var -> (Sc.name var,Sc.varType x)) (Sc.varNames x)) ++ varNames' xs
      varNames' [] = []
scadeInterface name (_:xs) = scadeInterface name xs
scadeInterface name [] = error $ "Couldn't find model "++show name

-- | Constructs a SCADE node that connects the testnode with the actual implementation SCADE node.
buildTest :: String -- ^ Name of the SCADE node
             -> [Sc.VarDecl] -- ^ Input variables of the node
             -> [Sc.VarDecl] -- ^ Output variables of the node
             -> Sc.Declaration
buildTest opname ins outs = UserOpDecl
  { userOpKind = Sc.Node
  , userOpImported = False
  , userOpInterface = InterfaceStatus Nothing False
  , userOpName = opname++"_test"
  , userOpSize = Nothing
  , userOpParams = ins
  , userOpReturns = [ VarDecl { Sc.varNames = [VarId "test_result" False False]
                              , Sc.varType = TypeBool
                              , Sc.varDefault = Nothing
                              , Sc.varLast = Nothing
                              } ]
  , userOpNumerics = []
  , userOpContent = DataDef { dataSignals = []
                            , dataLocals = outs
                            , dataEquations = [SimpleEquation [ Named $ Sc.name var | varDecl <- outs,var <- varNames varDecl ]
                                               (ApplyExpr (PrefixOp $ PrefixPath $ Path [opname])
                                                [IdExpr (Path [Sc.name n]) | varDecl <- ins, n <- varNames varDecl]),
                                               SimpleEquation [ Named "test_result" ]
                                               (ApplyExpr (PrefixOp $ PrefixPath $ Path [opname++"_testnode"])
                                                ([IdExpr (Path [Sc.name n]) | varDecl <- ins, n <- varNames varDecl] ++
                                                 [IdExpr (Path [Sc.name n]) | varDecl <- outs, n <- varNames varDecl]))
                                              ]
                            }
  }

-- | Convert a buchi automaton to SCADE.
buchiToScade :: String -- ^ Name of the resulting SCADE node
                -> Map String TypeExpr -- ^ Input variables
                -> Map String TypeExpr -- ^ Output variables
                -> BA [TypedExpr String] Integer -- ^ The buchi automaton
                -> Sc.Declaration
buchiToScade name ins outs buchi
  = UserOpDecl
    { userOpKind = Sc.Node
    , userOpImported = False
    , userOpInterface = InterfaceStatus Nothing False
    , userOpName = name++"_testnode"
    , userOpSize = Nothing
    , userOpParams = [ VarDecl [VarId n False False] tp Nothing Nothing
                     | (n,tp) <- Map.toList ins ++ Map.toList outs ]
    , userOpReturns = [VarDecl { Sc.varNames = [VarId "test_result" False False]
                               , Sc.varType = TypeBool
                               , Sc.varDefault = Nothing
                               , Sc.varLast = Nothing
                               }]
    , userOpNumerics = []
    , userOpContent = DataDef { dataSignals = []
                              , dataLocals = []
                              , dataEquations = [StateEquation
                                                 (StateMachine Nothing (buchiToStates buchi))
                                                 [] True
                                                ]
                              }
    }

-- | The starting state for a contract automaton.
startState :: BA [TypedExpr String] Integer -> Sc.State
startState buchi = Sc.State
  { stateInitial = True
  , stateFinal = False
  , stateName = "init"
  , stateData = DataDef { dataSignals = []
                        , dataLocals = []
                        , dataEquations = [SimpleEquation [Named "test_result"] (ConstBoolExpr True)]
                        }
  , stateUnless = [ stateToTransition cond trg
                  | i <- Set.toList (baInits buchi),
                    (cond,trg) <- Set.toList ((baTransitions buchi)!i)
                  ]++
                  [failTransition]
  , stateUntil = []
  , stateSynchro = Nothing
  }

-- | Constructs a transition into the `failState'.
failTransition :: Sc.Transition
failTransition = Transition (ConstBoolExpr True) Nothing (TargetFork Restart "fail")

-- | The state which is entered when a contract is violated.
--   There is no transition out of this state.
failState :: Sc.State
failState = Sc.State
  { stateInitial = False
  , stateFinal = False
  , stateName = "fail"
  , stateData = DataDef { dataSignals = []
                        , dataLocals = []
                        , dataEquations = [SimpleEquation [Named "test_result"] (ConstBoolExpr False)]
                        }
  , stateUnless = []
  , stateUntil = []
  , stateSynchro = Nothing
  }

-- | Translates a buchi automaton into a list of SCADE automaton states.
buchiToStates :: BA [TypedExpr String] Integer -> [Sc.State]
buchiToStates buchi = startState buchi :
                      failState :
                      [ Sc.State
                       { stateInitial = False
                       , stateFinal = False
                       , stateName = "st"++show num
                       , stateData = DataDef { dataSignals = []
                                             , dataLocals = []
                                             , dataEquations = [SimpleEquation [Named "test_result"] (ConstBoolExpr True)]
                                             }
                       , stateUnless = [ stateToTransition cond trg
                                       | (cond,trg) <- Set.toList trans ] ++
                                       [failTransition]
                       , stateUntil = []
                       , stateSynchro = Nothing
                       }
                     | (num,trans) <- Map.toList (baTransitions buchi) ]

-- | Given a state this function creates a transition into the state.
stateToTransition :: [TypedExpr String] -> Integer -> Sc.Transition
stateToTransition cond trg
  = Transition
    (relsToExpr cond)
    Nothing
    (TargetFork Restart ("st"++show trg))

exprToScade :: TypedExpr String -> Sc.Expr
exprToScade expr = case getValue expr of
  Var name lvl -> foldl (\e _ -> UnaryExpr UnPre e) (IdExpr $ Path [name]) [1..lvl]
  Value val -> valueToScade (getType expr) val
  BinIntExpr op l r -> Sc.BinaryExpr (case op of
                                         OpPlus -> BinPlus
                                         OpMinus -> BinMinus
                                         OpMult -> BinTimes
                                         OpDiv -> BinDiv
                                     ) (exprToScade (unfix l)) (exprToScade (unfix r))
  BinRelExpr rel l r -> BinaryExpr (case rel of
                                      BinLT -> BinLesser
                                      BinLTEq -> BinLessEq
                                      BinGT -> BinGreater
                                      BinGTEq -> BinGreaterEq
                                      BinEq -> BinEquals
                                      BinNEq -> BinDifferent
                                   ) (exprToScade (unfix l)) (exprToScade (unfix r))
  UnBoolExpr GTL.Not p -> Sc.UnaryExpr Sc.UnNot (exprToScade (unfix p))

valueToScade :: GTLType -> GTLValue (Fix (Typed (Term String))) -> Sc.Expr
valueToScade _ (GTLIntVal v) = Sc.ConstIntExpr v
valueToScade _ (GTLBoolVal v) = Sc.ConstBoolExpr v
valueToScade _ (GTLByteVal v) = Sc.ConstIntExpr (fromIntegral v)
valueToScade _ (GTLEnumVal v) = Sc.IdExpr $ Path [v]
valueToScade _ (GTLArrayVal xs) = Sc.ArrayExpr (fmap (exprToScade.unfix) xs)
valueToScade _ (GTLTupleVal xs) = Sc.ArrayExpr (fmap (exprToScade.unfix) xs)

relsToExpr :: [TypedExpr String] -> Sc.Expr
relsToExpr [] = Sc.ConstBoolExpr True
relsToExpr xs = foldl1 (Sc.BinaryExpr Sc.BinAnd) (fmap exprToScade xs)
