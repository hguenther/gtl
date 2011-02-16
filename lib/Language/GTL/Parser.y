{
module Language.GTL.Parser where

import Language.GTL.Token
import Language.GTL.Syntax

import Data.Maybe (mapMaybe)
}

%name gtl
%tokentype { Token }
%error { parseError }

%token
  "all"             { Key KeyAll }
  "always"          { Key KeyAlways }
  "connect"         { Key KeyConnect }
  "contract"        { Key KeyContract }
  "and"             { Key KeyAnd }
  "follows"         { Key KeyFollows }
  "model"           { Key KeyModel }
  "next"            { Key KeyNext }
  "not"             { Key KeyNot }
  "or"              { Key KeyOr }
  "in"              { Key KeyIn }
  "init"            { Key KeyInit }
  "verify"          { Key KeyVerify }
  "("               { Bracket Parentheses False }
  ")"               { Bracket Parentheses True }
  "["               { Bracket Square False }
  "]"               { Bracket Square True }
  "{"               { Bracket Curly False }
  "}"               { Bracket Curly True }
  ","               { Comma }
  ";"               { Semicolon }
  "<"               { LessThan }
  ">"               { GreaterThan }
  "="               { Equals }
  "."               { Dot }
  id                { Identifier $$ }
  string            { ConstString $$ }
  int               { ConstInt $$ }

%left "always" "next"
%left "or"
%left "and"
%left "follows"
%left "not"

%%

declarations : declaration declarations { $1:$2 }
             |                          { [] }

declaration : model_decl    { Model $1 }
            | connect_decl  { Connect $1 }
            | verify_decl   { Verify $1 }

model_decl : "model" "[" id "]" id model_args model_contract { ModelDecl
                                                               { modelName = $5
                                                               , modelType = $3
                                                               , modelArgs = $6
                                                               , modelContract = mapMaybe (\el -> case el of
                                                                                              Left c -> Just c
                                                                                              Right _ -> Nothing) $7
                                                               , modelInits = mapMaybe (\el -> case el of
                                                                                           Left _ -> Nothing
                                                                                           Right c -> Just c) $7
                                                               }
                                                             }

model_args : "(" model_args1 ")" { $2 }
           |                     { [] }

model_args1 : string model_args2 { $1:$2 }
            |                    { [] }

model_args2 : "," string model_args2 { $2:$3 }
            |                        { [] }

model_contract : "{" formulas_or_inits "}" { $2 }
               | ";"                       { [] }

formulas_or_inits : mb_contract formula ";" formulas_or_inits   { (Left $2):$4 }
                  | init_decl ";" formulas_or_inits             { (Right $1):$3 }
                  |                                             { [] }

mb_contract : "contract" { }
            |            { }

formulas : formula ";" formulas { $1:$3 }
         |                      { [] }

formula : lit "<" lit                 { BinRel BinLT $1 $3 }
        | lit ">" lit                 { BinRel BinGT $1 $3 }
        | lit "=" lit                 { BinRel BinEq $1 $3 }
        | var "in" "{" lits "}"       { Elem (fst $1) (snd $1) $4 True }
        | var "not" "in" "{" lits "}" { Elem (fst $1) (snd $1) $5 False }
        | "not" formula               { Not $2 }
        | formula "and" formula       { BinOp And $1 $3 }
        | formula "or" formula        { BinOp Or $1 $3 }
        | formula "follows" formula   { BinOp Follows $1 $3 }
        | "always" formula            { Always $2 }
        | "next" formula              { Next $2 }
        | "(" formula ")"             { $2 }

var : id        { (Nothing,$1) }
    | id "." id { (Just $1,$3) }

lit : int       { Constant $1 }
    | var       { Variable (fst $1) (snd $1) }

lits : lit comma_lits { $1:$2 }
     |                { [] }

comma_lits : "," lit comma_lits { $2:$3 }
           |                    { [] }

connect_decl : "connect" id "." id id "." id ";" { ConnectDecl $2 $4 $5 $7 }

verify_decl : "verify" "{" formulas "}" { VerifyDecl $3 }

init_decl : "init" id "all" { ($2,InitAll) }
          | "init" id int   { ($2,InitOne $3) }

{
parseError xs = error ("Parse error at "++show (take 5 xs))
}
