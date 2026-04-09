import std/[os, strutils, unittest]
import ../src/sushi/[model, native_modules, runtime]

proc newTestRuntime(): SushiRuntime =
  newRuntime()
    .registerNativeModule(buildIoModule())
    .registerNativeModule(buildBaseModule())
    .registerNativeModule(buildMathModule())

suite "sushi runtime":
  test "evaluates arithmetic":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("+ 1 2")
    check value.kind == Integer
    check value.intValue == 3

  test "supports classes and fields":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
class Test [] do
  field value
  fun init [x] do
    set self.value x
  end
end
var t [new Test 42]
t.value
""")
    check value.kind == Integer
    check value.intValue == 42

  test "supports default fields and instance methods":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
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
""")
    check value.kind == Integer
    check value.intValue == 42

  test "supports inheritance and super method calls":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
class Base [] do
  field {
    base 0
  }
  fun init [x] do
    set self.base x
  end
  fun score [bonus] do
    + self.base bonus
  end
end
class Child [Base] do
  field {
    extra 5
  }
  fun score [bonus] do
    + [score bonus] self.extra
  end
end
var child [new Child 7]
child.score 3
""")
    check value.kind == Integer
    check value.intValue == 15

  test "supports class methods":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
class Factory [] do
  fun Self.seed [x] do
    + x 1
  end
end
Factory.seed 41
""")
    check value.kind == Integer
    check value.intValue == 42

  test "supports lambdas with command bodies":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
var inc [fn [x] + x 1]
inc 41
""")
    check value.kind == Integer
    check value.intValue == 42

  test "supports lambdas with block bodies":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
var total 40
var add [fn [x] do
  set total [+ total x]
  eval total
end]
add 2
""")
    check value.kind == Integer
    check value.intValue == 42

  test "supports lambdas with bracket and parenthesized bodies":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
var x 41
var via-brackets [fn [y] [+ y 1]]
var via-parens [fn [] (x + 1)]
+ [via-brackets 40] [via-parens]
""")
    check value.kind == Integer
    check value.intValue == 83

  test "supports lambda lexical capture by reference":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
var base 10
var add-base [fn [x] + x base]
set base 2
add-base 40
""")
    check value.kind == Integer
    check value.intValue == 42

  test "supports returned lambdas capturing outer scope":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
fun make-adder [n] do
  fn [x] + x n
end
var add-two [make-adder 2]
add-two 40
""")
    check value.kind == Integer
    check value.intValue == 42

  test "supports do-times from the prelude":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
var total 0
do-times 4 do
  set total [+ total it]
end
eval total
""")
    check value.kind == Integer
    check value.intValue == 6

  test "supports captured block introspection":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
fun block-count [b] do
  command-count b
end
block-count do
  1
  2
end
""")
    check value.kind == Integer
    check value.intValue == 2

  test "supports command-at on captured blocks":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
fun first-command-size [b] do
  object-count [eval [command-at b 0]]
end
first-command-size do
  1 2
  3
end
""")
    check value.kind == Integer
    check value.intValue == 2

  test "supports command-at with computed index":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
fun first-command-size [b] do
  var i 0
  object-count [eval [command-at b [eval-value i]]]
end
first-command-size do
  1 2
  3
end
""")
    check value.kind == Integer
    check value.intValue == 2

  test "supports command-at inside while":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
fun inspect [b] do
  var i 0
  var out 0
  while (i < 1) do
    set out [object-count [eval [command-at b [eval-value i]]]]
    set i 1
  end
  eval out
end
inspect do
  1 2
  3
end
""")
    check value.kind == Integer
    check value.intValue == 2

  test "supports cond":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
var x [cond do
  F: 1
  T: 7
end]
eval x
""")
    check value.kind == Integer
    check value.intValue == 7

  test "supports cond command conditions":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
var line "+ 1 2 3"
cond do
  (line eq ":quit"): 1
  T: 7
end
""")
    check value.kind == Integer
    check value.intValue == 7

  test "supports cond blocks":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
cond do
  F: do
    1
  end
  T: do
    + 1 2 3
  end
end
""")
    check value.kind == Integer
    check value.intValue == 6

  test "loads prose script":
    let runtime = newTestRuntime()
    let value = runtime.evaluateFile(getCurrentDir() / "scripts" / "prose.sushi")
    check not value.isNil

  test "runs shipped script":
    let runtime = newTestRuntime()
    let value = runtime.runFile(getCurrentDir() / "scripts" / "test.sushi")
    check value.kind != Text or not value.textValue.startsWith("error:")
