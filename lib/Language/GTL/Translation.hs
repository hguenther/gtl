{-# LANGUAGE GADTs, ExistentialQuantification, StandaloneDeriving, ScopedTypeVariables,
    TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses #-}
{-| Translates GTL expressions into LTL formula.
 -}
module Language.GTL.Translation(
  gtl2ba
  ) where

import Language.GTL.Expression as GTL
import Language.GTL.Types as GTL
import Language.GTL.LTL as LTL
import Language.GTL.Buchi
import Data.Foldable
import Prelude hiding (foldl,foldl1,concat,mapM)

import Data.Set as Set

-- | Translates a GTL expression into a buchi automaton.
--   Needs a user supplied function that converts a list of atoms that have to be
--   true into the variable type of the buchi automaton.
gtl2ba :: (Ord v,Show v) => Maybe Integer -> TypedExpr v -> BA [TypedExpr v] Integer
gtl2ba cy e = ltl2ba $ gtlToLTL cy e

instance (Ord v,Show v) => AtomContainer [TypedExpr v] (TypedExpr v) where
  atomsTrue = []
  atomSingleton True x = [x]
  atomSingleton False x = [distributeNot x]
  compareAtoms x y = compareAtoms' EEQ x y
    where
      compareAtoms' p [] [] = p
      compareAtoms' p [] _  = case p of
        EEQ -> EGT
        EGT -> EGT
        _ -> EUNK
      compareAtoms' p (x:xs) ys = case compareAtoms'' p x ys of
        Nothing -> case p of
          EEQ -> compareAtoms' ELT xs ys
          ELT -> compareAtoms' ELT xs ys
          ENEQ -> ENEQ
          _ -> EUNK
        Just (p',ys') -> compareAtoms' p' xs ys'
      compareAtoms'' p x [] = Nothing
      compareAtoms'' p x (y:ys) = case compareExpr x y of
        EEQ -> Just (p,ys)
        ELT -> case p of
          EEQ -> Just (ELT,ys)
          ELT -> Just (ELT,ys)
          _ -> Just (EUNK,ys)
        EGT -> case p of
          EEQ -> Just (EGT,ys)
          EGT -> Just (EGT,ys)
          _ -> Just (EUNK,ys)
        ENEQ -> Just (ENEQ,ys)
        EUNK -> case compareAtoms'' p x ys of
          Nothing -> Nothing
          Just (p',ys') -> Just (p',y:ys')
  mergeAtoms [] ys = Just ys
  mergeAtoms (x:xs) ys = case mergeAtoms' x ys of
    Nothing -> Nothing
    Just ys' -> mergeAtoms xs ys'
    where
      mergeAtoms' x [] = Just [x]
      mergeAtoms' x (y:ys) = case compareExpr x y of
        EEQ -> Just (y:ys)
        ELT -> Just (x:ys)
        EGT -> Just (y:ys)
        EUNK -> case mergeAtoms' x ys of
          Nothing -> Nothing
          Just ys' -> Just (y:ys')
        ENEQ -> Nothing

getSteps :: Integer -> TimeSpec -> Integer
getSteps _ NoTime = 0
getSteps _ (TimeSteps s) = s
getSteps cy (TimeUSecs s) = s `div` cy

getUSecs :: TimeSpec -> Integer
getUSecs (TimeUSecs s) = s

gtlToLTL :: (Ord v,Show v) => Maybe Integer -> TypedExpr v -> LTL (TypedExpr v)
gtlToLTL cycle_time expr = fst $ gtlToLTL' 0 cycle_time expr

-- | Translate a GTL expression into a LTL formula.
gtlToLTL' :: (Ord v,Show v) => Integer -> Maybe Integer -> TypedExpr v -> (LTL (TypedExpr v),Integer)
gtlToLTL' clk cycle_time expr
  | getType expr == GTLBool = case getValue expr of
    Var _ _ -> (Atom expr,clk)
    Value (GTLBoolVal x) -> (Ground x,clk)
    BinBoolExpr op l r -> let (lhs,clk1) = gtlToLTL' clk cycle_time (unfix l)
                              (rhs,clk2) = gtlToLTL' clk1 cycle_time (unfix r)
                          in case op of
                            GTL.And -> (LTL.Bin LTL.And lhs rhs,clk2)
                            GTL.Or -> (LTL.Bin LTL.Or lhs rhs,clk2)
                            GTL.Implies -> (LTL.Bin LTL.Or (LTL.Un LTL.Not lhs) rhs,clk2)
                            GTL.Until NoTime -> (LTL.Bin LTL.Until lhs rhs,clk2)
                            GTL.Until ti -> case cycle_time of
                              Just rcycle_time -> (foldl (\expr _ -> LTL.Bin LTL.Or rhs (LTL.Bin LTL.And lhs (LTL.Un LTL.Next expr))) rhs [1..(getSteps rcycle_time ti)],clk2)
                              Nothing -> (LTL.Bin LTL.Or rhs (LTL.Bin LTL.And
                                                              (LTL.Bin LTL.And
                                                               (Atom (Typed GTLBool $ ClockReset clk2 (getUSecs ti)))
                                                               lhs)
                                                              (LTL.Un LTL.Next
                                                               (LTL.Bin LTL.Until (LTL.Bin LTL.And
                                                                                   lhs
                                                                                   (Atom (Typed GTLBool $ ClockRef clk2)))
                                                                (LTL.Bin LTL.And
                                                                 rhs
                                                                 (Atom (Typed GTLBool $ ClockReset clk2 0))
                                                                )
                                                               )
                                                              )
                                                             ),clk2+1)
    BinRelExpr rel lhs rhs -> case fmap Atom $ flattenRel rel (unfix lhs) (unfix rhs) of
      [e] -> (e,clk)
      es -> (foldl1 (LTL.Bin LTL.And) es,clk)
    UnBoolExpr op p -> let (arg,clk1) = gtlToLTL' clk cycle_time (unfix p)
                       in case op of
                         GTL.Not -> (LTL.Un LTL.Not arg,clk1)
                         GTL.Always -> (LTL.Bin LTL.UntilOp (LTL.Ground False) arg,clk1)
                         GTL.Next NoTime -> (LTL.Un LTL.Next arg,clk1)
                         GTL.Next ti -> case cycle_time of
                           Just rcycle_time -> (foldl (\expr _ -> LTL.Bin LTL.And arg (LTL.Un LTL.Next expr)) arg [2..(getSteps rcycle_time ti)],clk1)
                         GTL.Finally NoTime -> (LTL.Bin LTL.Until (LTL.Ground True) arg,clk1)
                         GTL.Finally ti -> case cycle_time of
                           Just rcycle_time -> (foldl (\expr _ -> LTL.Bin LTL.Or arg (LTL.Un LTL.Next expr)) arg [2..(getSteps rcycle_time ti)],clk1)
                         GTL.After ti -> case cycle_time of
                           Just rcycle_time -> (foldl (\expr _ -> LTL.Un LTL.Next expr) arg [1..(getSteps rcycle_time ti)],clk1)
    IndexExpr _ _ -> (Atom expr,clk)
    Automaton buchi -> (LTLAutomaton (renameStates $ optimizeTransitionsBA $ minimizeBA $ expandAutomaton $ baMapAlphabet (fmap unfix) $ renameStates buchi),clk)
  | otherwise = error "Internal error: Non-bool expression passed to gtlToLTL"
    where
      flattenRel :: Relation -> TypedExpr v -> TypedExpr v -> [TypedExpr v]
      flattenRel rel lhs rhs = case (getValue lhs,getValue rhs) of
        (Value (GTLArrayVal xs),Value (GTLArrayVal ys)) -> zipWith (\x y -> Typed GTLBool (BinRelExpr rel x y)) xs ys
        (Value (GTLArrayVal xs),_) -> zipWith (\x i -> Typed GTLBool (BinRelExpr rel x (Fix $ Typed (getType $ unfix x) (IndexExpr (Fix rhs) i)))) xs [0..]
        (_,Value (GTLArrayVal ys)) -> zipWith (\i y -> Typed GTLBool (BinRelExpr rel (Fix $ Typed (getType $ unfix y) (IndexExpr (Fix lhs) i)) y)) [0..] ys
        (Value (GTLTupleVal xs),Value (GTLTupleVal ys)) -> zipWith (\x y -> Typed GTLBool (BinRelExpr rel x y)) xs ys
        (Value (GTLTupleVal xs),_) -> zipWith (\x i -> Typed GTLBool (BinRelExpr rel x (Fix $ Typed (getType $ unfix x) (IndexExpr (Fix rhs) i)))) xs [0..]
        (_,Value (GTLTupleVal ys)) -> zipWith (\i y -> Typed GTLBool (BinRelExpr rel (Fix $ Typed (getType $ unfix y) (IndexExpr (Fix lhs) i)) y)) [0..] ys
        _ -> [Typed GTLBool (BinRelExpr rel (Fix lhs) (Fix rhs))]

expandAutomaton :: (Ord t,Ord v) => BA [TypedExpr v] t -> BA [TypedExpr v] t
expandAutomaton ba = ba { baTransitions = fmap (\ts -> Set.fromList 
                                                       [ (Set.toList cond,trg)
                                                       | (cs,trg) <- Set.toList ts,
                                                         let cs_expr = case cs of
                                                               [] -> Typed GTLBool (Value (GTLBoolVal True))
                                                               [c] -> c
                                                               _ -> foldl1 (\x y -> Typed GTLBool (BinBoolExpr GTL.And (Fix x) (Fix y))) cs,
                                                         cond <- expandExpr cs_expr
                                                       ]) (baTransitions ba) }

expandExpr :: Ord v => TypedExpr v -> [Set (TypedExpr v)]
expandExpr expr
  | getType expr == GTLBool = case getValue expr of
    Var _ _ -> [Set.singleton expr]
    Value (GTLBoolVal False) -> []
    Value (GTLBoolVal True) -> [Set.empty]
    BinBoolExpr op l r -> case op of
      GTL.And -> [ Set.union lm rm | lm <- expandExpr (unfix l), rm <- expandExpr (unfix r) ]
      GTL.Or -> expandExpr (unfix l) ++ expandExpr (unfix r)
      GTL.Implies -> expandExpr (Typed GTLBool (BinBoolExpr GTL.Or (Fix $ Typed GTLBool (UnBoolExpr GTL.Not l)) r))
      GTL.Until _ -> error "Can't use until in state formulas yet"
    BinRelExpr _ _ _ -> [Set.singleton expr]
    UnBoolExpr op p -> case op of
      GTL.Not -> let expandNot [] = [Set.empty]
                     expandNot (x:xs) = let res = expandNot xs
                                        in Set.fold (\at cur -> fmap (Set.insert (distributeNot at)) res ++ cur) res x
                 in expandNot (expandExpr $ unfix p)
      GTL.Next _ -> error "Can't use next in state formulas yet"
      GTL.Always -> error "Can't use always in state formulas yet"
    IndexExpr _ _ -> [Set.singleton expr]
    Automaton _ -> error "Can't use automata in state formulas yet"