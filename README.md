# Sushi

Sushi is a small scripting language with first-class syntax. Source is read into objects. Commands decide which objects to evaluate and which to keep as syntax. That model is the center of the language. It is also why Sushi can express control flow, records, classes, and DSLs without introducing separate subsystems for each.

## Build and run

```bash
nimble test
nimble buildbin
nimble buildlib
```

The CLI supports:

```bash
sushi
sushi --run path/to/file.sushi
sushi fmt path/to/file.sushi
sushi fmt --write path/to/file.sushi
sushi pen input.sushi output.html
sushi pen --watch input.sushi output.html
```

## A small demo

```sushi
record Counter count

fun bump-twice [counter amount] do
  set counter.count (counter.count + [eval amount])
  set counter.count (counter.count + [eval amount])
end

var c [new Counter 10]
bump-twice c (1 + 2)

if (c.count > 15) do
  write-line "count: \(c.count)"
end
```

The important part is not the syntax. It is the timing.

- `record Counter count` builds a normal construct you can instantiate with `new`.
- `bump-twice` receives raw arguments.
- `amount` is syntax until `eval` asks for its value.
- updates still happen through normal command-shaped code.

## First principles

At the top level, a Sushi file is a stream of commands.

```sushi
write-line "hello"
write-line "world"
```

The reader turns source text into objects:

- numbers: `1`, `42`, `3.14`
- booleans: `T`, `F`
- text: `"hello"`
- symbols: `name`, `write-line`, `count+=`
- commands
- blocks
- sequences and tables

That distinction matters:

- `"hello"` is already a value
- `hello` is a symbol
- `[+ 1 2]` is a command object
- `do ... end` is a block object

Sushi does not apply one universal eager-evaluation rule. Each command chooses what to evaluate. Native commands do this directly. User-defined functions also receive raw argument objects by default.

That is the working model:

1. Read source into objects.
2. Pass those objects to a command.
3. Let the command decide what evaluation means.

## Syntax shapes

Bracket commands delay execution:

```sushi
var expr [+ 1 2]
eval expr
```

Grouped expressions are also syntax objects:

```sushi
set x (x + 1)
```

Sushi has list and table literals:

```sushi
#[1 2 3]
{ name "Miso" hp 10 }
```

Lists are ordered sequences:

```sushi
var xs #[10 20 30]
xs.(1)
```

Tables map keys to values:

```sushi
var hero { name "Miso" hp 10 }
hero.name
hero.(name)
```

With table literals, bare symbol keys stay literal keys. They are not evaluated as variable lookups unless you use an explicitly evaluated form.

Indexing uses `.(...)`:

```sushi
xs.(1)
hero.(name)
```

Blocks are objects too:

```sushi
do
  write-line "hello"
end
```

A block is not executed just because it exists. Some command has to run it.

## Reader and parser conveniences

### `\\` is shorthand for `do ... end`

`\\` is a reader rewrite. It is not a separate runtime feature.

Trailing `\\` opens an indented block:

```sushi
doc Main \\
  div { class "prose" } \\
    p { } "Hello"
```

This is rewritten before parsing to the equivalent `do ... end` form.

Inline `\\` rewrites the rest of the line into a block:

```sushi
fun into-html [xs] \\ into-html-from xs 0
```

That is equivalent to:

```sushi
fun into-html [xs] do
  into-html-from xs 0
end
```

This matters because `pen.sushi` uses `\\` heavily, but the semantics are still ordinary Sushi blocks.

### `else` and `elif`

`else` and `elif` are part of the everyday surface syntax:

```sushi
if F do
  1
else
  2
end
```

They behave exactly like you would expect from ordinary conditional chaining.

Under the hood, the reader rewrites them into explicit `end` / `do` structure before parsing. That detail matters only if you are trying to understand how much of Sushi is implemented as reader sugar rather than as special evaluator logic.

### List and table reader forms

Sushi has built-in list and table literal syntax:

```sushi
#[1 2 3]
{ name "Miso" hp 10 }
```

At the reader level, these are rewritten to ordinary command forms:

```sushi
[list 1 2 3]
[table name "Miso" hp 10]
```

That matters because list and table literals are not special evaluator cases. They are convenient surface syntax for normal Sushi objects.

### Spaced operator suffixes

Sushi allows whitespace before an operator suffix ending in `=` when the left side is:

- a plain symbol, such as `x += 2`
- a dot access ending in a plain symbol, such as `a.b += 3`

So these parse the same:

```sushi
x += 2
x+= 2

a.b += 3
a.b+= 3
```

Operationally, you can think of:

```sushi
a.b += 3
```

as turning into a command whose final callable name is `b+=` on the dot chain. In other words, it behaves like the parsed form `[a.b+= 3]`. This keeps update syntax inside the normal command/object model instead of introducing a separate assignment grammar.

## Core features

### Variables and control flow

Bindings are explicit:

```sushi
var hp 10
set hp (hp - 1)

let current hp do
  write-line current
end
```

- `var` defines a binding in the current scope
- `set` updates an existing binding or assignable target
- `let` creates a nested scope, binds one name, and evaluates a block in that scope

Control flow is command-based and block-based:

```sushi
if (hp > 0) do
  write-line "alive"
end

cond do
  (hp > 10): "healthy"
  (hp > 0): "hurt"
  T: "down"
end

while (hp > 0) do
  set hp (hp - 1)
end
```

### Functions

User functions receive raw arguments:

```sushi
fun twice [x] do
  + [eval x] [eval x]
end

twice (1 + 2)
```

That is why Sushi functions are naturally macro-like. The function controls evaluation timing.

Lambdas use `fn`:

```sushi
var add1 [fn [x] (x + 1)]
```

### Modules

Modules are loaded with `use`:

```sushi
use io
use syntax global
```

`use module` binds the module value. `use module global` also exposes its exports in the current module scope.

### Records

Records are part of the everyday language surface:

```sushi
record V3 x y z
var v [new V3 1 2 3]
v.x= 10
v.y
```

At the language level, a record is a convenient way to define a field-based type with an initializer and setters.

Under the hood, `record` is implemented in the prelude by building class syntax and evaluating it with `syntax.eval-node`. That matters because it shows the design directly: useful surface features can be built from ordinary syntax objects and ordinary evaluation.

### Classes

Classes use the same model, not a separate one:

```sushi
class Counter [] do
  field {
    count 40
  }

  fun bump [delta] do
    set self.count [+ self.count delta]
  end

  fun read [] do
    self.count
  end
end

var counter [new Counter]
counter.bump 2
counter.read
```

Classes support:

- fields with optional defaults
- instance methods with `fun`
- inheritance with `class Child [Base]`
- construction with `new`
- field access with dot syntax

Methods still receive raw arguments. Object orientation does not change the evaluation model.

## Error handling

Errors are values only after you catch them. Until then, a failing evaluation raises and unwinds normally.

### `catch`

`catch` evaluates an expression and intercepts any raised error:

```sushi
catch do
  syntax.eval-node [table "kind" "bogus"]
end do
  eval error-message
end
```

With one argument, `catch` returns `nil` on failure. With a second block argument, it runs that block and binds the message text to `error-message`.

Use `catch` when failure is part of normal control flow and you want to recover explicitly.

### `??`

`??` is a postfix error-coalescing operator. It evaluates the left side and returns the right side only if the left side fails.

```sushi
[maybe-read-config] ?? "default"
```

If the right side is a block, that block also receives `error-message`:

```sushi
[maybe-read-config] ?? do
  "config failed: \(error-message)"
end
```

Use `??` when you want a local fallback value and want the expression to continue.

### `!!`

`!!` is the terminating form. It evaluates the left side, and if that fails, it runs a fallback block and then exits with status `1`.

```sushi
[start-server] !! do
  write-line "fatal: \(error-message)"
end
```

Use `!!` for command-line entrypoints and other cases where failure should report context and then stop the process.

`catch`, `??`, and `!!` fit the same general rule as the rest of Sushi: they are ordinary commands/operators that decide when to evaluate their operands and what to do with failure.

## The eval family

This is the part to learn precisely.

### `eval`

`eval` evaluates one object as code.

Use it when a function or method receives delayed syntax and wants its meaning now.

```sushi
fun show-value [x] do
  write-line [eval x]
end
```

### `eval-value`

`eval-value` resolves to the underlying value without the normal command-call step.

Use it when you want the value behind a symbol or delayed object, rather than asking Sushi to treat that object as code to execute.

This is useful in helpers that work with counters, indices, iterators, and stored values.

### `eval-here`

`eval-here` evaluates delayed syntax in the current local scope while preserving captured context.

Use it when helper-local bindings should be visible while evaluating caller-originated syntax.

`pen` uses this for inline HTML insertion through `@`.

### `replay`

`replay` executes a captured block in a replay scope.

Use it for DSL blocks and helper bodies that need both:

- names defined inside the helper
- names captured from the caller

If a block DSL works in Sushi, `replay` is usually the reason.

### `run`

`run` starts from source text:

```sushi
run "write-line \"hello\""
```

Use `run` when you have text and want it parsed and executed. Use `eval` when you already have a Sushi object.

### `syntax.eval-node`

`syntax.eval-node` evaluates a constructed AST node.

Use it when you are generating syntax programmatically. `record` uses this path to turn generated class syntax into a real definition.

### `raw` and `capture`

`capture` stores caller-authored syntax together with its environment.

`raw` gives you syntax as syntax, without treating captured syntax as something to replay through its captured environment.

Together with `eval`, `eval-here`, and `replay`, these are the tools for writing syntax-aware abstractions.

## Why captured syntax exists

When Sushi delays caller code, it keeps more than the syntax object. It also keeps the caller environment associated with that syntax.

That is why a helper can receive a user expression or block, evaluate it later, and still have names resolve the way the caller expected.

Without captured syntax, delayed evaluation would be fragile. With it, delayed syntax is usable as a normal programming technique.

## `pen`: a DSL built from ordinary Sushi

`pen.sushi` is the clearest example of the language model paying off.

It defines local commands such as:

- `html`
- `head`
- `body`
- `div`
- `p`
- `h1`
- `@`

Then it replays a caller block inside that local environment:

```sushi
fun build-html [blk] do
  var parts #[]

  fun div [kv blk] \\ element "div" kv blk
  fun p args \\ text-tag-call "p" args
  fun @ [html] do
    append parts [eval-here html]
  end

  replay blk
  into-html parts
end
```

A `pen` program can then look like this:

```sushi
doc Main \\
  html {} \\
    head {} \\
      title-tag "Demo"
    body {} \\
      div { class "prose" } \\
        h1 "Sushi"
        p "Rendered through a Sushi DSL."
```

This is not special parser support. It is ordinary Sushi:

- blocks are values
- helper-local commands are ordinary functions
- caller blocks carry captured context
- `replay` runs the block in the right mixed scope
- `eval-here` handles expression-style insertion
- the result is reduced to HTML text

That is the language in one example.

## Why Sushi

Sushi is built around one idea instead of many separate rules.

- Source becomes objects.
- Commands choose evaluation.
- Delayed syntax is normal.
- Blocks are data.
- Records can be built from syntax tools.
- Classes keep the same evaluation model.
- DSLs like `pen` are ordinary library code.

The result is a language where advanced features are not exceptions to the core model. They are consequences of it.
