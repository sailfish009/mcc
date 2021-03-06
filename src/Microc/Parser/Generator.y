{
module Microc.Parser.Generator where
import Microc.Scanner.Generator
import Microc.Ast
import Data.Text (pack)
import Prelude hiding (fst, snd)

}

%name parse
%tokentype { Lexeme }
%error { parseError }

%token
  int    { LInt   $$ }
  float  { LFloat $$ }
  id     { LId    $$ }
  ptype  { LType  $$ }
  char   { LCharLit $$ }
  string { LStrLit $$ }
  bool   { LBool  $$ }
  null   { LNull }
  return { LRet }
  struct { LStruct }
  sizeof { LSizeof }
  '='    { LAssign }
  ','    { LComma }
  ';'    { LSemi }
  '('    { LPAREN }
  ')'    { RPAREN }
  '{'    { LBRACE }
  '}'    { RBRACE }
  for    { LFor }
  while  { LWhile }
  if     { LIf }
  else   { LElse }
  '+'    { LAdd }
  '-'    { LSub }
  '*'    { LMul }
  '/'    { LDiv }
  '=='   { LEqual }
  '!='   { LNeq }
  '<'    { LLess }
  '<='   { LLeq }
  '>'    { LGreater }
  '>='   { LGeq }
  '&&'   { LAnd }
  '||'   { LOr  }
  '!'    { LNot }
  '&'    { LBitAnd }
  '|'    { LBitOr  }
  '**'   { LPow }
  '.'    { LDot }
  '->'   { LArrow }

%nonassoc NOELSE
%nonassoc else
%right '='
%left '|'
%left '&'
%left '||'
%left '&&'
%left '==' '!='
%left '<' '>' '<=' '>='
%left '+' '-'
%left '*' '/'
%right '**'
%right '!' NEG
%left '.' '->'


%%

program:
  decls { Program (reverse $ fst $1) (reverse $ snd $1) (reverse $ thd $1) }

decls:
   {- empty -} { ([], [], []) }
 | decls sdecl { (($2 : fst $1), (snd $1), (thd $1)) }
 | decls vdecl { ((fst $1), ($2 : snd $1), (thd $1)) }
 | decls fdecl { ((fst $1), (snd $1), ($2 : thd $1)) }

fdecl:
   typ id '(' formals_opt ')' '{' vdecl_list stmt_list '}'
     { Function { typ = $1,
         name = pack $2,
         formals = $4,
         locals = reverse $7,
         body = reverse $8 } }

formals_opt:
    {- empty -} { [] }
  | formal_list   { reverse $1 }

formal_list:
    typ id                   { [Bind $1 (pack $2)] }
  | formal_list ',' typ id { Bind $3 (pack $4) : $1 }

typ:
    ptype stars     { foldr (const Pointer) $1 $2 }
  | struct id stars { foldr (const Pointer) (TyStruct (pack $2)) $3 }

stars:
    { [] }
  | stars '*' { $2 : $1 }
  -- A hack to get around the power operator
  | stars '**' { $2 : $2 : $1 }

sdecl:
    struct id '{' vdecl_list '}' ';' { Struct (pack $2) (reverse $4) }

vdecl_list:
    {- empty -}    { [] }
  | vdecl_list vdecl { $2 : $1 }

vdecl:
   typ id ';' { Bind $1 (pack $2) }

stmt_list:
    {- empty -}  { [] }
  | stmt_list stmt { $2 : $1 }

stmt:
    expr ';' { Expr $1 }
  | return ';' { Return Noexpr }
  | return expr ';' { Return $2 }
  | '{' stmt_list '}' { Block (reverse $2) }
  | if '(' expr ')' stmt %prec NOELSE { If $3 $5 (Block []) }
  | if '(' expr ')' stmt else stmt    { If $3 $5 $7 }
  | for '(' expr_opt ';' expr ';' expr_opt ')' stmt { For $3 $5 $7 $9 }
  | while '(' expr ')' stmt { While $3 $5 }

expr_opt:
    {- empty -} { Noexpr }
  | expr          { $1 }

expr:
    int                    { Literal $1 }
  | float                  { Fliteral $1 }
  | char                   { CharLit $1 }
  | string                 { StrLit (pack $1) }
  | bool                   { BoolLit $1 }
  | null                   { Null }
  | id                     { Id (pack $1) }
  | expr '+'  expr         { Binop  Add  $1 $3 }
  | expr '-'  expr         { Binop  Sub  $1 $3 }
  | expr '*'  expr         { Binop  Mult $1 $3 }
  | expr '/'  expr         { Binop  Div  $1 $3 }
  | expr '==' expr         { Binop  Equal $1 $3 }
  | expr '!=' expr         { Binop  Neq  $1 $3 }
  | expr '<'  expr         { Binop  Less $1 $3 }
  | expr '<=' expr         { Binop  Leq  $1 $3 }
  | expr '>'  expr         { Binop  Greater $1 $3 }
  | expr '>=' expr         { Binop  Geq  $1 $3 }
  | expr '&'  expr         { Binop  BitAnd  $1 $3 }
  | expr '|'  expr         { Binop  BitOr   $1 $3 }
  | expr '&&' expr         { Binop  And  $1 $3 }
  | expr '||' expr         { Binop  Or   $1 $3 }
  | expr '**'  expr        { Binop  Power $1 $3 }
  | '-' expr %prec NEG     { Unop Neg $2 }
  | '*' expr %prec NEG     { Deref $2 }
  -- A hack to get around having the power operator
  | '**' expr %prec NEG    { Deref (Deref $2) }
  | '&' expr %prec NEG     { Addr $2 }
  | '!' expr               { Unop Not  $2 }
  | expr '=' expr          { Assign $1 $3 }
  | id '(' actuals_opt ')' { Call (pack $1) $3 }
  | '(' typ ')' expr %prec NEG { Cast $2 $4 }
  | expr '.' expr          { Access $1 $3 }
  | expr '->' expr         { Access (Deref $1) $3}
  | sizeof '(' typ ')'     { Sizeof $3 }
  | '(' expr ')'           { $2 }

actuals_opt:
    {- empty -} { [] }
  | actuals_list  { reverse $1 }

actuals_list:
    expr                    { [$1] }
  | actuals_list ',' expr { $3 : $1 }

{
parseError _ = error "Unable to parse tokens"
fst (a, _, _) = a
snd (_, b, _) = b
thd (_, _, c) = c
}
