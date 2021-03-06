{
{-# LANGUAGE BangPatterns #-}  
{-| The GTL Lexer  
 -}
module Language.GTL.Parser.Lexer (gtlLexer,lexGTL) where

import Language.GTL.Parser.Token
import Language.GTL.Parser.Monad

import Control.Monad.State
import Control.Monad.Error
}

$letter = [a-zA-Z\_]
$digit10 = [0-9]

tokens:-
  $white+                        { skip }
  "//".*                         { skip }
  "/*"                           { nestedComment }
  after                          { un GOpAfter }
  all                            { key KeyAll }
  always                         { un GOpAlways }
  and                            { bin GOpAnd }
  automaton                      { key KeyAutomaton }
  bool                           { key KeyBool }
  byte                           { key KeyByte }
  connect                        { key KeyConnect }
  contract                       { key KeyContract }
  cycle\-time                    { key KeyCycleTime }
  enum                           { key KeyEnum }
  false                          { key KeyFalse }
  float                          { key KeyFloat }
  guaranteed                     { key KeyGuaranteed }
  implies                        { bin GOpImplies }
  init                           { key KeyInit }
  int                            { key KeyInt }
  instance                       { key KeyInstance }
  local                          { key KeyLocal }
  model                          { key KeyModel }
  finally                        { un GOpFinally }
  next                           { un GOpNext }
  exists                         { key KeyExists }
  final                          { key KeyFinal }
  not                              { un GOpNot }
  or                             { bin GOpOr }
  output                         { key KeyOutput }
  input				 { key KeyInput }
  in                             { bin GOpIn }
  state                          { key KeyState }
  transition                     { key KeyTransition }
  true                           { key KeyTrue }
  type                           { key KeyType }
  until                          { key KeyUntil }
  verify                         { key KeyVerify }
  "("                            { tok $ Bracket Parentheses False }
  ")"                            { tok $ Bracket Parentheses True }
  "["                            { tok $ Bracket Square False }
  "]"                            { tok $ Bracket Square True }
  "{"                            { tok $ Bracket Curly False }
  "}"                            { tok $ Bracket Curly True }
  ";"                            { tok Semicolon }
  ":="                           { bin GOpAssign }
  ":"                            { tok Colon }
  "."                            { tok Dot }
  ","                            { tok Comma }
  "<="                           { bin GOpLessThanEqual }
  "<"                            { bin GOpLessThan }
  "=>"                           { bin GOpImplies }
  ">="                           { bin GOpGreaterThanEqual }
  ">"                            { bin GOpGreaterThan }
  "="                            { bin GOpEqual }
  "!="                           { bin GOpNEqual }
  "!"                            { un GOpNot }
  "+"				 { bin GOpPlus }
  "-"                            { bin GOpMinus }
  "*"                            { bin GOpMult }
  "/"                            { bin GOpDiv }
  "^"                            { bin GOpPow }
  "#in"                          { tok CtxIn }
  "#out"                         { tok CtxOut }
  "'" $letter ($letter | $digit10)*              { withStr $ \s -> ConstEnum (tail s) }
  \" ([\x00-\xff] # [\\\"] | \\ [\x00-\xff])* \" { withStr $ \s -> ConstString (read s) }
  $letter ($letter | $digit10)*                  { withStr Identifier }
  $digit10+                                      { withStr $ \s -> ConstInt (read s) }

{
type AlexInput = (Posn,Char,String)
  
alexGetChar :: AlexInput -> Maybe (Char,AlexInput)
alexGetChar (p,_,c:cs) = Just (c,(movePosn p c,c,cs))
alexGetChar (_,_,[]) = Nothing

alexGetByte :: AlexInput -> Maybe (Int,AlexInput)
alexGetByte inp = case alexGetChar inp of
  Nothing -> Nothing
  Just (c,inp') -> Just (ord c,inp')

alexInputPrevChar :: AlexInput -> Char
alexInputPrevChar (_,c,_) = c

alexGetInput :: GTLParser AlexInput
alexGetInput = do
  st <- get
  return (parserPos st,parserChr st,parserInp st)

alexGetScd :: GTLParser Int
alexGetScd = gets parserScd

alexSetInput :: AlexInput -> GTLParser ()
alexSetInput (pos,c,inp) = modify (\st -> st { parserPos = pos 
                                             , parserChr = c
                                             , parserInp = inp })

type Action r = AlexInput -> Int -> GTLParser r

nestedComment :: Action Token
nestedComment _ _ = do  
  input <- alexGetInput
  go 1 input
  where go 0 input = do
          alexSetInput input
          lexGTL
        go n input = do
          case alexGetChar input of
            Nothing -> err input
            Just (c,input) -> do
              case c of
                '*' -> case alexGetChar input of
                  Nothing -> err input
                  Just ('/',input) -> go (n-1) input
                  Just (c,input) -> go n input
                '/' -> case alexGetChar input of
                  Nothing -> err input
                  Just ('*',input) -> go (n+1) input
                  Just (c,input) -> go n input
                _ -> go n input
        err input = do
          alexSetInput input
          throwError "error in nested comment"

lexGTL :: GTLParser Token
lexGTL = do
  inp <- alexGetInput
  scd <- alexGetScd
  case alexScan inp scd of
    AlexEOF -> return EOF
    AlexError err -> throwError "lexer error"
    AlexSkip inp' _ -> alexSetInput inp' >> lexGTL
    AlexToken inp' len act -> alexSetInput inp' >> act inp len

gtlLexer :: (Token -> GTLParser a) -> GTLParser a
gtlLexer f = lexGTL >>= f

key :: KeyWord -> Action Token
key w _ _ = return $ Key w

un :: UnOp -> Action Token
un o _ _ = return $ Unary o

bin :: BinOp -> Action Token
bin o _ _ = return $ Binary o

tok :: Token -> Action Token
tok t _ _ = return t

withStr :: (String -> Token) -> Action Token
withStr f (_,_,input) i = return $ f (take i input)

skip _ _ = lexGTL

}