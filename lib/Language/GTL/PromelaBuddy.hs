{- Lascia ch'io pianga
   mia cruda sorte,
   e che sospiri la libertà.
   Il duolo infranga queste ritorte
   de' miei martiri sol per pietà.

                       -- G.F. Händel
-}
{-# LANGUAGE GADTs #-}
module Language.GTL.PromelaBuddy where

import Language.GTL.Translation
import Language.Scade.Syntax as Sc
import Language.Promela.Syntax as Pr
import Language.GTL.LTL
import Language.GTL.ScadeAnalyzer
import Language.GTL.Syntax as GTL

import Data.Map as Map
import Data.Set as Set
import Control.Monad.Identity
import Control.Monad.State
import Prelude hiding (foldl,concat)
import Data.Foldable
import Data.List (intersperse)

data TransModel = TransModel
                  { varsInit :: Map String String
                  , varsIn :: Map String Integer
                  , varsOut :: Map String (Map (Maybe (String,String)) (Set Integer))
                  , stateMachine :: Buchi ([Integer],[Integer]) --[GTLAtom]
                  , checkFunctions :: [String]
                  } deriving Show

data TransProgram = TransProgram
                    { transModels :: Map String TransModel
                    , transClaims :: [Buchi [Integer]]
                    , claimChecks :: [String]
                    } deriving Show

translateContracts :: [Sc.Declaration] -> [GTL.Declaration] -> [Pr.Module]
translateContracts scade decls = translateContracts' (buildTransProgram scade decls)

varName :: Bool -> String -> String -> Integer -> String
varName nvr mdl var lvl = (if nvr
                           then "never_"
                           else "conn_")++mdl++"_"++var++(if lvl==0
                                                          then ""
                                                          else "_"++show lvl)

translateContracts' :: TransProgram -> [Pr.Module]
translateContracts' prog 
  = let include = Pr.CDecl $ unlines ["\\#include <cudd/cudd.h>"
                                     ,"\\#include <cudd_arith.h>"
                                     ,"\\#include <assert.h>"
                                     ,"DdManager* manager;"]
        states = [ Pr.CState ("DdNode* "++varName False name var n) "Global" (Just "NULL")
                 | (name,mdl) <- Map.toList $ transModels prog
                 , (var,hist) <- Map.toList (varsIn mdl) 
                 , n <- [0..hist] ] ++
                 [ Pr.CState ("DdNode* "++varName True name var lvl) "Global" (Just "NULL")
                 | (name,mdl) <- Map.toList $ transModels prog
                 , (var,set) <- Map.toList (varsOut mdl)
                 , lvl <- case Map.lookup Nothing set of
                   Nothing -> []
                   Just lvls -> [0..(Set.findMax lvls)]
                 ]
        procs = fmap (\(name,mdl) -> let steps = translateModel name mdl
                                         proc = Pr.ProcType { Pr.proctypeActive = Nothing
                                                            , Pr.proctypeName = name
                                                            , Pr.proctypeArguments = []
                                                            , Pr.proctypePriority = Nothing
                                                            , Pr.proctypeProvided = Nothing
                                                            , Pr.proctypeSteps = steps
                                                            }
                                     in (name,proc)) (Map.toList (transModels prog))
        check_funcs = Pr.CCode $ unlines $
                      [ impl | mdl <- Map.elems (transModels prog), impl <- checkFunctions mdl ] ++
                      claimChecks prog ++
                      [ unlines $ ["void reset_"++name++"(State* now) {"] ++
                        ["  "++vname lvl++" = "++(if lvl==0
                                                  then "DD_ONE(manager);"
                                                  else vname (lvl-1))
                        | (from,tos) <- Map.toList (varsOut mdl), (to,lvls) <- Map.toList tos, 
                          let hist = case to of
                                Nothing -> Set.findMax lvls
                                Just (q,n) -> (varsIn ((transModels prog)!q))!n, 
                          let vname l = case to of
                                Just (q,n) -> "now->"++varName False q n l
                                Nothing -> "now->"++varName True name from l,
                          lvl <- reverse [0..hist] ]++
                        ["}"]
                      | (name,mdl) <- Map.toList (transModels prog) ]
        init = prInit [ prAtomic $ [ StmtCCode $ unlines $
                                     [ "manager = Cudd_Init(32,0,CUDD_UNIQUE_SLOTS,CUDD_CACHE_SLOTS,0);"] ++ 
                                     [ "now."++varName False name var clvl++" = Cudd_ReadOne(manager);"
                                     | (name,mdl) <- Map.toList $ transModels prog, 
                                       (var,lvl) <- Map.toList $ varsIn mdl,
                                       clvl <- [0..lvl]
                                     ] ++
                                     [ "now."++varName True name var lvl++" = Cudd_ReadOne(manager);"
                                     | (name,mdl) <- Map.toList $ transModels prog,
                                       (var,outs) <- Map.toList $ varsOut mdl,
                                       lvl <- case Map.lookup Nothing outs of
                                         Nothing -> []
                                         Just lvls -> [0..(Set.findMax lvls)]
                                     ] ++
                                     concat [ let trgs = if Map.member var (varsIn mdl)
                                                         then ["now.conn_"++name++"_"++var]
                                                         else [ case outp of
                                                                   Nothing -> "now.never_"++name++"_"++var
                                                                   Just (q,n) -> "now.conn_"++q++"_"++n
                                                              | outp <- Map.keys ((varsOut mdl)!var) ]
                                              in [ head trgs++" = "++e++";"
                                                 , "Cudd_Ref("++head trgs++");"] ++
                                                 [ trg++" = "++head trgs | trg <- tail trgs ]
                                            | (name,mdl) <- Map.toList (transModels prog),
                                              (var,e) <- Map.toList (varsInit mdl) ]
                                   ]
                        ++ [ StmtRun name [] | (name,_) <- procs ]
                      ]
        nevers = [ prNever $ translateNever never
                 | never <- transClaims prog ]
    in [include]++states++[check_funcs]++[ pr | (_,pr) <- procs]++[init]++nevers

translateModel :: String -> TransModel -> [Pr.Step]
translateModel name mdl
  = let states = fmap (\(st,entr)
                       -> Pr.StmtLabel ("st"++show st) $
                          prAtomic [ Pr.StmtPrintf ("ENTER "++show st++"\n") [],
                                     Pr.StmtCCode $ unlines $ ["reset_"++name++"(&now);" ] ++ [ "assign_"++name++show n++"(&now);" | n <- snd $ vars entr ],
                                     prIf [ (if not $ Prelude.null $ fst $ vars nentr
                                             then [ Pr.StmtCExpr Nothing $ unwords $ intersperse "&&"
                                                    [ "cond_"++name++show n++"(&now)" | n <- fst $ vars nentr ] ]
                                             else []) ++ [Pr.StmtGoto $ "st"++show succ ]
                                          | succ <- Set.toList $ successors entr, let nentr = (stateMachine mdl)!succ ]
                                   ]
                      ) (Map.toList $ stateMachine mdl)
        inits = prIf [ [prAtomic $ (if not $ Prelude.null $ fst $ vars entr
                                    then [ Pr.StmtCExpr Nothing $ unwords $ intersperse "&&"
                                           [ "cond_"++name++show n++"(&now)" | n <- fst $ vars entr ] ]
                                    else []) ++ [Pr.StmtGoto $ "st"++show st ] ]
                     | (st,entr) <- Map.toList $ stateMachine mdl, isStart entr ]
    in fmap toStep $ inits:states

translateNever :: Buchi [Integer] -> [Pr.Step]
translateNever buchi
  = let rbuchi = translateGBA buchi
        showSt (i,j) = show i++"_"++show j
        states = fmap (\(st,entr)
                        -> let body = prAtomic [ prIf [ (if Prelude.null (vars nentr)
                                                        then []
                                                        else [Pr.StmtCExpr Nothing $ unwords $ intersperse "&&"
                                                              [ "cond__never"++show n++"(&now)" | n <- vars nentr ]]) ++
                                                        [Pr.StmtGoto $ "st"++showSt succ]
                                                      | succ <- Set.toList $ successors entr, 
                                                        let nentr = rbuchi!succ ]
                                               ]
                           in Pr.StmtLabel ("st"++showSt st) $ if finalSets entr
                                                               then Pr.StmtLabel ("accept"++showSt st) body
                                                               else body
                      ) (Map.toList rbuchi)
        inits = prIf [ (if Prelude.null (vars entr)
                        then []
                        else [Pr.StmtCExpr Nothing $ unwords $ intersperse "&&"
                              [ "cond__never"++show n++"(&now)" | n <- vars entr ]]) ++
                       [Pr.StmtGoto $ "st"++showSt st]
                     | (st,entr) <- Map.toList rbuchi,
                       isStart entr
                     ]
    in fmap toStep $ StmtSkip:inits:states

parseGTLAtom :: Map GTLAtom (Integer,Bool,String) -> Maybe (String,Map String (Map (Maybe (String,String)) (Set Integer))) -> GTLAtom -> ((Integer,Bool),Map GTLAtom (Integer,Bool,String))
parseGTLAtom mp arg at
  = case Map.lookup at mp of
    Just (i,isinp,_) -> ((i,isinp),mp)
    Nothing -> let (idx,isinp,res) = case at of
                     GTLRel rel lhs rhs -> parseGTLRelation mp arg rel lhs rhs
                     GTLVar q n lvl v -> parseGTLRelation mp arg BinEq (ExprVar (q,n) lvl) (ExprConst v)
               in ((idx,isinp),Map.insert at (idx,isinp,res) mp)
        

parseGTLRelation :: BuddyConst a => Map GTLAtom (Integer,Bool,String) -> Maybe (String,Map String (Map (Maybe (String,String)) (Set Integer))) -> Relation -> GTL.Expr (Maybe String,String) a -> GTL.Expr (Maybe String,String) a -> (Integer,Bool,String)
parseGTLRelation mp arg rel lhs rhs
  = let lvars = [ (v,lvl) | ((Nothing,v),lvl) <- getVars lhs, Map.member v outps ]
        rvars = [ (v,lvl) | ((Nothing,v),lvl) <- getVars rhs, Map.member v outps ]
        idx = fromIntegral $ Map.size mp
        name = case arg of
          Nothing -> Nothing
          Just (n,_) -> Just n
        rname = case name of
          Nothing -> error "Invalid use of unqualified variable"
          Just n -> n
        outps = case arg of
          Nothing -> Map.empty
          Just (_,s) -> s
        (res,isinp) = (case lvars of
                          [] -> case rhs of
                            ExprVar (Nothing,n) lvl -> if Map.member n outps
                                                       then (createBuddyAssign idx rname n (outps!n) (relTurn rel) lhs,False)
                                                       else error "No output variable in relation"
                            _ -> case rvars of
                              [] -> (createBuddyCompare idx name rel lhs rhs,True)
                              _ -> error "Output variables must be alone"
                          _ -> case lhs of
                            ExprVar (Nothing,n) lvl -> (createBuddyAssign idx rname n (outps!n) rel rhs,False)
                            _ -> case lvars of
                              [] -> (createBuddyCompare idx name rel lhs rhs,True)
                              _ -> error "Output variables must be alone"
                      ) :: (String,Bool)
    in (idx,isinp,res)

createBuddyAssign :: BuddyConst a => Integer -> String -> String -> Map (Maybe (String,String)) (Set Integer) -> Relation -> GTL.Expr (Maybe String,String) a -> String
createBuddyAssign count q n outs rel expr
  = let trgs = [ maybe ("now->"++varName True q n lvl) (\(q',n') -> "now->"++varName False q' n' lvl) var 
               | (var,lvls) <- Map.toList outs
               , lvl <- Set.toList lvls]
        (cmd2,te) = case rel of
          BinEq -> ([],e)
          BinNEq -> ([],"Cudd_Not("++e++")")
          GTL.BinGT -> (["DdNode* extr = "++e++";",
                         "Cudd_Ref(extr);",
                         "CUDD_ARITH_TYPE min;",
                         "int min_found = Cudd_bddMinimum(manager,extr,0,&min);",
                         "assert(min_found);",
                         "Cudd_RecursiveDeref(manager,extr);"
                        ],"Cudd_Not(Cudd_bddLessThanEqual(manager,min,0))")
          BinGTEq -> (["DdNode* extr = "++e++";",
                       "Cudd_Ref(extr);",
                       "CUDD_ARITH_TYPE min;",
                       "int min_found = Cudd_bddMinimum(manager,extr,0,&min);",
                       "assert(min_found);",
                       "Cudd_RecursiveDeref(manager,extr);"
                      ],"Cudd_Not(Cudd_bddLessThan(manager,min,0))")
          GTL.BinLT -> (["DdNode* extr = "++e++";",
                         "Cudd_Ref(extr);",
                         "CUDD_ARITH_TYPE max;",
                         "int max_found = Cudd_bddMaximum(manager,extr,0,&max);",
                         "assert(max_found);",
                         "Cudd_RecursiveDeref(manager,extr);"
                        ],"Cudd_bddLessThan(manager,max,0)")
          BinLTEq -> (["DdNode* extr = "++e++";",
                       "Cudd_Ref(extr);",
                       "CUDD_ARITH_TYPE max;",
                       "int max_found = Cudd_bddMaximum(manager,extr,0,&max);",
                       "assert(max_found);",
                       "Cudd_RecursiveDeref(manager,extr);"
                      ],"Cudd_bddLessThanEqual(manager,max,0)")
        (cmd,de,_,e) = createBuddyExpr 0 (Just q) expr
    in unlines ([ "void assign_"++q++show count++"(State* now) {"] ++
                fmap ("  "++) (cmd++cmd2) ++
                ["  "++head trgs++" = "++te++";"]++
                fmap (\trg -> "  "++trg++" = "++head trgs++";") (tail trgs)++
                ["  Cudd_Ref("++head trgs++");"
                ]++
                fmap ("  "++) de ++
                ["}"])

createBuddyCompare :: BuddyConst a => Integer -> Maybe String -> Relation -> GTL.Expr (Maybe String,String) a -> GTL.Expr (Maybe String,String) a -> String
createBuddyCompare count q rel expr1 expr2
  = let (cmd1,de1,v,e1) = createBuddyExpr 0 q expr1
        (cmd2,de2,_,e2) = createBuddyExpr v q expr2
    in unlines $ ["int cond_"++(maybe "_never" id q)++show count++"(State* now) {"]++
       fmap ("  "++) (cmd1++cmd2)++
       ["  DdNode* lhs = "++e1++";"
       ,"  Cudd_Ref(lhs);"
       ,"  DdNode* rhs = "++e2++";"
       ,"  Cudd_Ref(rhs);"
       ,"  int res;"
       ]++(case rel of
              GTL.BinEq -> ["  res = Cudd_bddAnd(manager,lhs,rhs)!=Cudd_Not(Cudd_ReadOne(manager));"]
              GTL.BinNEq -> ["  res = !((lhs==rhs) && Cudd_bddIsSingleton(manager,lhs,0));"]
              GTL.BinLT -> ["  CUDD_ARITH_TYPE lval,rval;",
                            "  int lval_found = Cudd_bddMinimum(manager,lhs,0,&lval);",
                            "  int rval_found = Cudd_bddMaximum(manager,rhs,0,&rval);",
                            "  res = lval_found && rval_found && (lval < rval);"]
              GTL.BinLTEq -> ["  CUDD_ARITH_TYPE lval,rval;",
                              "  int lval_found = Cudd_bddMinimum(manager,lhs,0,&lval);",
                              "  int rval_found = Cudd_bddMaximum(manager,rhs,0,&rval);",
                              "  res = lval_found && rval_found && (lval <= rval);"]
              GTL.BinGT -> ["  CUDD_ARITH_TYPE lval,rval;",
                            "  int lval_found = Cudd_bddMaximum(manager,lhs,0,&lval);",
                            "  int rval_found = Cudd_bddMinimum(manager,rhs,0,&rval);",
                            "  res = lval_found && rval_found && (lval > rval);"]
              GTL.BinGTEq -> ["  CUDD_ARITH_TYPE lval,rval;",
                              "  int lval_found = Cudd_bddMaximum(manager,lhs,0,&lval);",
                              "  int rval_found = Cudd_bddMinimum(manager,rhs,0,&rval);",
                              "  res = lval_found && rval_found && (lval >= rval);"]
              _ -> ["  //Unimplemented relation: "++show rel]
          )++
       ["  Cudd_RecursiveDeref(manager,rhs);",
        "  Cudd_RecursiveDeref(manager,lhs);"]++
       fmap ("  "++) (de2++de1)++
       ["  return res;",
        "}"]

class BuddyConst t where
  buddyConst :: t -> String

instance BuddyConst Int where
  buddyConst n = "Cudd_bddSingleton(manager,"++show n++",0)"

instance BuddyConst Bool where
  buddyConst v = let var = "Cudd_bddIthVar(manager,0)"
                 in if v then var
                    else "Cudd_Not("++var++")"

createBuddyExpr :: BuddyConst a => Integer -> Maybe String -> GTL.Expr (Maybe String,String) a -> ([String],[String],Integer,String)
createBuddyExpr v mdl (ExprConst i) = ([],[],v,buddyConst i)
createBuddyExpr v mdl (ExprVar (q,n) lvl) = case mdl of
  Nothing -> case q of
    Just rq -> ([],[],v,"now->"++varName True rq n lvl)
    Nothing -> error "verify claims must not contain qualified variables"
  Just rmdl -> ([],[],v,"now->"++varName False rmdl n lvl)
createBuddyExpr v mdl (ExprBinInt op lhs rhs)
  = let (cmd1,de1,v1,e1) = createBuddyExpr v mdl lhs
        (cmd2,de2,v2,e2) = createBuddyExpr v1 mdl rhs
    in (cmd1++cmd2++["DdNode* tmp"++show v2++" = "++e1++";",
                     "Cudd_Ref(tmp"++show v2++");",
                     "DdNode* tmp"++show (v2+1)++" = "++e2++";",
                     "Cudd_Ref(tmp"++show (v2+1)++");"],
        ["Cudd_RecursiveDeref(manager,tmp"++show (v2+1)++");"
        ,"Cudd_RecursiveDeref(manager,tmp"++show v2++");"]++de2++de1,
        v2+2,
        (case op of
            OpPlus -> "Cudd_bddPlus"
            OpMinus -> "Cudd_bddMinus"
            OpMult -> "Cudd_bddTimes"
            OpDiv -> "Cudd_bddDivide"
        )++"(manager,tmp"++show v2++",tmp"++show (v2+1)++",0)")

--solveForLHS :: Maybe String -> String -> Expr Int -> Expr Int -> x

buildTransProgram :: [Sc.Declaration] -> [GTL.Declaration] -> TransProgram
buildTransProgram scade decls
  = let models = [ m | Model m <- decls ]
        conns = [ c | Connect c <- decls ]
        claims = [ v | Verify v <- decls ]
        
        tmodels1 = Map.fromList $ fmap (\m -> let (inp_vars,outp_vars) = scadeInterface ((modelArgs m)!!0) scade
                                                  outp_map = Map.fromList $ fmap (\(var,_) -> (var,Map.empty)) outp_vars
                                                  hist = maximumHistory (modelContract m)
                                              in (modelName m,
                                                  TransModel { varsInit = Map.fromList [ (name,case e of
                                                                                             InitAll -> "Cudd_ReadOne(manager)"
                                                                                             InitOne i -> "Cudd_bddSingleton(manager,"++show i++",0)")
                                                                                       | (name,e) <- modelInits m ]
                                                             , varsIn = Map.fromList $ [ (v,hist!(Nothing,v)) | (v,_) <- inp_vars ]
                                                             , varsOut = outp_map
                                                             , stateMachine = undefined
                                                             , checkFunctions = undefined
                                                             })) models
        (tclaims,fclaims) = foldl (\(sms,cmp1) claim
                                   -> let (sm,fm) = runState
                                                    (gtlsToBuchi (\ats -> do 
                                                                     mp <- get
                                                                     let (c,nmp) = foldl (\(cs,cmp2) at -> let ((n,True),nmp) = parseGTLAtom cmp2 Nothing at
                                                                                                           in (n:cs,nmp)
                                                                                         ) ([],mp) ats
                                                                     put nmp
                                                                     return c
                                                                 ) (fmap (GTL.ExprNot) $ verifyFormulas claim))
                                                    cmp1
                                      in (sm:sms,fm)
                                  ) ([],Map.empty) claims
        
        tmodels2 = foldl (\cmdls c -> Map.adjust (\mdl -> mdl { varsOut = Map.insertWith (Map.unionWith Set.union)
                                                                          (connectFromVariable c)
                                                                          (Map.singleton (Just (connectToModel c,connectToVariable c)) (Set.singleton 0))
                                                                          (varsOut mdl)
                                                              }) (connectFromModel c) cmdls) tmodels1 conns
        tmodels3 = foldl (\cmdls never ->
                           foldl (\cmdls' ((Just q,n),lvl) ->
                                   Map.adjust (\mdl -> mdl { varsOut = Map.insertWith (Map.unionWith Set.union)
                                                                       n (Map.singleton Nothing (Set.singleton lvl))
                                                                       (varsOut mdl)
                                                           }) q cmdls'
                                 ) cmdls $ concat (fmap getVars (verifyFormulas never))
                         ) tmodels2 claims
        tmodels4 = foldl (\cur m -> Map.adjust
                                    (\entr -> let (sm,fm) = runState (gtlsToBuchi
                                                                      (\ats -> do
                                                                          mp <- get
                                                                          let (c,a,nmp) = foldl (\(chks,ass,cmp) at
                                                                                                 -> let ((n,f),nmp) = parseGTLAtom cmp (Just (modelName m,varsOut entr)) at
                                                                                                    in (if f then (n:chks,ass,nmp)
                                                                                                        else (chks,n:ass,nmp))
                                                                                                ) ([],[],mp) ats
                                                                          put nmp
                                                                          return (c,a)
                                                                      ) (modelContract m)) Map.empty
                                              in entr { stateMachine = sm
                                                      , checkFunctions = fmap (\(_,_,f) -> f) (Map.elems fm)
                                                      }
                                    ) (modelName m) cur) tmodels3 models
    in TransProgram { transModels = tmodels4
                    , transClaims = tclaims
                    , claimChecks = fmap (\(_,_,f) -> f) $ Map.elems fclaims
                    }