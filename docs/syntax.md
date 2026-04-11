# Sushi Parser Syntax

This document describes the concrete grammar implemented by `src/sushi/parser.nim`.
It is an implementation reference, not a language tutorial. If this document and the
parser disagree, `src/sushi/parser.nim` is the source of truth.

## Lexical Conventions

```ebnf
identifier-start   = "A"…"Z" | "a"…"z" | "_" ;
identifier-rest    = identifier-start | "0"…"9" | "-" ;

identifier         = identifier-start , { identifier-rest } ;
keyword-symbol     = ":" , identifier ;

operator-char      = "!" | "$" | "%" | "&" | "*" | "+" | "-" | "." | "/" |
                     ":" | "<" | "=" | ">" | "?" | "@" | "^" | "~" ;
operator           = operator-char , { operator-char } ;

symbol-token       = identifier [ operator-suffix ]
                   | keyword-symbol
                   | operator
                   | "(" | ")" | "[" | "]" | "{" | "}" | "#[" ;

operator-suffix    = { operator-char - "=" } , "=" ;

boolean            = "T" | "F" ;
number             = digit , { digit } , [ "." , digit , { digit } ] ;

text               = "\"" , { text-char | escape | template } , "\"" ;
escape             = "\" , ( "n" | "r" | "t" | "\" | "\"" | other-char ) ;
template           = "\(" , template-source , ")" ;

comment            = ";" , { any-char - newline } ;
terminator         = newline ;
line-continuation  = "\" , { " " | "\t" } , [ comment ] , newline ;
```

Notes:

- Identifiers may contain trailing operator suffixes such as `x=`, `x+=`, `name??=`.
- `:` followed by an identifier-like name tokenizes as one symbol, for example `:done`.
- `#[` tokenizes as a distinct symbol token and is then rewritten by the reader to `[` `list`.
- Text interpolation uses `\(... )`, and the embedded source is parsed as Sushi syntax.
- A backslash only has meaning for line continuation or inside text literals.

## Grammar

```ebnf
script             = { terminator } , [ command , { { terminator } , command } ] , { terminator } ;

command            = command-object , { command-object } ;

command-object     = object ;
```

`command-object` has one parser-specific exception: for non-head positions, unary-prefix
forms like `-x` and `not x` are parsed as expressions before tuple normalization.

```ebnf
object             = tuple-object ;
tuple-object       = non-tuple-object , { ":" , non-tuple-object } ;

non-tuple-object   = number
                   | boolean
                   | text
                   | postfix-expression ;

postfix-expression = symbol-driven-object ,
                     { dot-access } ,
                     { postfix-binary } ;

symbol-driven-object
                   = symbol
                   | parenthesized-expression
                   | bracket-command
                   | table
                   | block
                   | lambda ;

symbol             = symbol-token ;

parenthesized-expression
                   = "(" , expression , ")" ;

bracket-command    = "[" , { terminator } , [ command-object , { command-object } ] , { terminator } , "]" ;

table              = "{" , { terminator } ,
                     [ object , object , { { terminator } , object , object } ] ,
                     { terminator } , "}" ;

block              = "do" , { terminator } ,
                     [ command , { { terminator } , command } ] ,
                     { terminator } , "end" ;

lambda             = "fn" , bracket-command , lambda-body ;
lambda-body        = block | command ;

dot-access         = "." , ( symbol | "(" , expression , ")" ) ;
postfix-binary     = "??" , non-tuple-object
                   | "!!" , non-tuple-object ;
```

## Expressions

Expressions are precedence-based. The parser uses prefix parsing for unary operators and
precedence climbing for infix operators.

```ebnf
expression         = prefix-expression , { infix-tail } ;

prefix-expression  = unary-operator , expression
                   | primary-expression ;

primary-expression = number
                   | boolean
                   | text
                   | postfix-expression ;

unary-operator     = "not" | "-" ;
```

The effective infix grammar is:

```ebnf
infix-operator     = ":"
                   | "??"
                   | "!!"
                   | "or"
                   | "and"
                   | "eq"
                   | "not-eq"
                   | "<"
                   | ">"
                   | "+"
                   | "-"
                   | "*"
                   | "/"
                   | "%"
                   | "^"
                   | "." ;
```

Precedence and associativity, from lowest to highest:

| Precedence | Operators           | Associativity |
|-----------:|---------------------|---------------|
| 0          | `:` `??` `!!`       | left          |
| 1          | `or`                | left          |
| 2          | `and`               | left          |
| 3          | `eq` `not-eq`       | left          |
| 4          | `<` `>`             | left          |
| 5          | `+` `-`             | left          |
| 6          | `*` `/` `%`         | left          |
| 7          | `^`                 | right         |
| 8          | `.`                 | left          |

## Parser Notes

### Tuple normalization

`:` is parsed as an infix operator and then normalized into a sequence-like tuple form.
That affects both plain objects and parenthesized expressions.

Examples:

```text
a : b : c
(a : b : c)
```

Both parse through `:` command nodes first, then normalize into a flat tuple/sequence value.

### Dot access and grouped dot index

Dot syntax has two parser forms:

```text
a.b
a.(1 + 2)
```

- `a.b` parses as a `.` command with a symbol rhs.
- `a.(expr)` parses as a `.` command whose rhs is wrapped with the internal
  `:dot-index` marker.
- `.` has the strongest infix precedence, so `a.b + c` groups as `(+ (. a b) c)`.

### Spaced operator suffixes

The parser allows whitespace between an identifier-like lhs and an operator suffix ending
in `=`, but only in specific cases:

```text
a.b = 3
a.b += 1
x += 2
```

These parse the same as:

```text
a.b= 3
a.b+= 1
x+= 2
```

This absorption is only allowed when the lhs is:

- a plain symbol without an attached operator suffix, or
- a dot access whose final rhs is a plain symbol without an attached operator suffix.

### Reader replacements

Before parsing, the reader rewrites exact symbol-token sequences. Current built-in rules include:

```text
#[   => [ list
else => end do
elif => end \n if
```

So `#[1 2]` is parsed through the normal bracket-command path as `[list 1 2]`, not through a dedicated list-literal grammar rule.

### Text literals are not operators

Operator matching only applies to `Symbol` tokens. A text literal whose contents are `"."`
is still just text and does not begin dot parsing.

Example:

```text
render "."
```

### String templates

Inside text literals, `\(... )` embeds Sushi syntax and expects exactly one parsed object.

Example:

```text
"x \(y + 1)"
```

If the embedded source parses to one command with one object, that object is inserted.
If it parses to a multi-object command, the whole command is inserted.

## Short Examples

```text
a.b += 1
a.(1 + 2)
(a : b : c)
"x \(y + 1)"
```
