import std/[dynlib, os, osproc, streams, strutils, unittest]
import ../src/sushi/[embed, model, runtime]
import ../src/sushi/native_modules

proc newTestRuntime(): SushiRuntime =
  newEmbeddedRuntime()

when defined(windows):
  const sharedLibraryName = "sushi.dll"
elif defined(macosx):
  const sharedLibraryName = "libsushi.dylib"
else:
  const sharedLibraryName = "libsushi.so"

const
  projectRoot = currentSourcePath.parentDir.parentDir
  dynamicLibraryPath = projectRoot / "build" / sharedLibraryName
  dynamicLibraryCache = projectRoot / "build" / "nimcache" / "dynlib-test"
  dynamicLibrarySource = projectRoot / "src" / "sushilib.nim"
  binaryPath =
    when defined(windows):
      projectRoot / "build" / "sushi.exe"
    else:
      projectRoot / "build" / "sushi"
  binaryCache = projectRoot / "build" / "nimcache" / "bin-test"
  binarySource = projectRoot / "src" / "sushi.nim"

type
  SushiRuntimeNewProc = proc (): pointer {.cdecl.}
  SushiRuntimeNewWithArgsProc = proc (argc: cint; argv: cstringArray): pointer {.cdecl.}
  SushiRuntimeFreeProc = proc (handle: pointer) {.cdecl.}
  SushiRuntimeEvalProc = proc (handle: pointer; source: cstring; status: ptr cint): cstring {.cdecl.}
  SushiRuntimeEvalFileProc = proc (handle: pointer; filePath: cstring; status: ptr cint): cstring {.cdecl.}
  SushiStringFreeProc = proc (value: cstring) {.cdecl.}

proc buildDynamicLibrary() =
  createDir(projectRoot / "build")
  createDir(projectRoot / "build" / "nimcache")
  let command = [
    "nim",
    "c",
    "--nimcache:" & dynamicLibraryCache,
    "--app:lib",
    "-o:" & dynamicLibraryPath,
    dynamicLibrarySource
  ]
  let result = execCmdEx(command.join(" "), workingDir = projectRoot)
  doAssert result.exitCode == 0, result.output
  doAssert fileExists(dynamicLibraryPath)

proc buildBinary() =
  createDir(projectRoot / "build")
  createDir(projectRoot / "build" / "nimcache")
  let command = [
    "nim",
    "c",
    "--nimcache:" & binaryCache,
    "-o:" & binaryPath,
    binarySource
  ]
  let result = execCmdEx(command.join(" "), workingDir = projectRoot)
  doAssert result.exitCode == 0, result.output
  doAssert fileExists(binaryPath)

proc runBinaryWithInput(input: string; workingDir = projectRoot): tuple[exitCode: int, output: string] =
  let process = startProcess(binaryPath, workingDir = workingDir, options = {poStdErrToStdOut})
  defer: close(process)

  let inputHandle = process.inputStream
  inputHandle.write(input)
  inputHandle.flush()
  inputHandle.close()

  result.output = process.outputStream.readAll()
  result.exitCode = waitForExit(process)

proc stripAnsi(text: string): string =
  var index = 0
  while index < text.len:
    if text[index] == '\e':
      inc index
      if index < text.len and text[index] == '[':
        inc index
        while index < text.len and text[index] notin {'@' .. '~'}:
          inc index
        if index < text.len:
          inc index
      continue
    result.add(text[index])
    inc index

proc withWorkingDir(path: string; body: proc ()) =
  let originalDir = getCurrentDir()
  setCurrentDir(path)
  try:
    body()
  finally:
    setCurrentDir(originalDir)

proc loadSymbol[T](library: LibHandle; symbolName: string): T =
  let symbol = symAddr(library, symbolName)
  doAssert not symbol.isNil, "missing symbol: " & symbolName
  cast[T](symbol)

proc callEval(evalProc: SushiRuntimeEvalProc; stringFree: SushiStringFreeProc;
    runtime: pointer; source: string): tuple[status: cint, text: string] =
  var status: cint = -1
  let raw = evalProc(runtime, source, addr status)
  check not raw.isNil
  result = (status, $raw)
  stringFree(raw)

proc callEvalFile(evalFileProc: SushiRuntimeEvalFileProc; stringFree: SushiStringFreeProc;
    runtime: pointer; filePath: string): tuple[status: cint, text: string] =
  var status: cint = -1
  let raw = evalFileProc(runtime, filePath, addr status)
  check not raw.isNil
  result = (status, $raw)
  stringFree(raw)

suite "sushi runtime":
  test "evaluates arithmetic":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("+ 1 2")
    check value.kind == Integer
    check value.intValue == 3

  test "binds argc as count and argv as list":
    let runtime = newEmbeddedRuntime(@["first", "second"])
    let argc = runtime.environment.find(newSymbol("argc"))
    let argv = runtime.environment.find(newSymbol("argv"))
    check argc.kind == Integer
    check argc.intValue == 2
    check argv.kind == Sequence
    check argv.items.len == 2
    check argv.items[0].kind == Text
    check argv.items[0].textValue == "first"
    check argv.items[1].kind == Text
    check argv.items[1].textValue == "second"

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

  test "loads the embedded prelude without scripts on disk":
    let tempDir = getTempDir() / "sushi-embedded-prelude-test"
    createDir(tempDir)
    withWorkingDir(tempDir, proc () =
      let runtime = newEmbeddedRuntime()
      let value = runtime.evaluate("""
var total 0
do-times 4 do
  set total [+ total it]
end
eval total
""")
      check value.kind == Integer
      check value.intValue == 6
    )

  test "loads embedded built-in modules without scripts on disk":
    let tempDir = getTempDir() / "sushi-embedded-modules-test"
    createDir(tempDir)
    withWorkingDir(tempDir, proc () =
      let runtime = newEmbeddedRuntime()
      let value = runtime.evaluate("""
use format global
format-source "+   20   22"
""")
      check value.kind == Text
      check value.textValue == "+ 20 22"
    )

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

  test "parses printable terminal input":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use terminal global
use io
var event [parse-key "a"]
event.text
""")
    check value.kind == Text
    check value.textValue == "a"

  test "parses enter as a distinct key event":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use terminal global
use io
var event [parse-key "\n"]
event.kind
""")
    check value.kind == Text
    check value.textValue == "enter"

  test "parses kitty shift-enter":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use terminal global
use io
var event [parse-key [io.concat esc "[13;2u"]]
event.kind
""")
    check value.kind == Text
    check value.textValue == "shift-enter"

  test "parses alternate shift-enter":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use terminal global
use io
var event [parse-key [io.concat esc "[27;2;13~"]]
event.kind
""")
    check value.kind == Text
    check value.textValue == "shift-enter"

  test "parses arrow keys":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use terminal global
use io
var event [parse-key [io.concat esc "[A"]]
event.kind
""")
    check value.kind == Text
    check value.textValue == "up"

  test "parses backspace":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use terminal global
use io
var event [parse-key del]
event.kind
""")
    check value.kind == Text
    check value.textValue == "backspace"

  test "marks shift-enter as submit":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use terminal global
use io
var event [parse-key [io.concat esc "[13;2u"]]
event.submit
""")
    check value.kind == Boolean
    check value.boolValue

  test "marks unknown escape sequences":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use terminal global
use io
var event [parse-key [io.concat esc "[999~"]]
event.kind
""")
    check value.kind == Text
    check value.textValue == "unknown"

  test "readline inserts text into the middle of the buffer":
    var state = initReadlineState("> ")
    discard state.applyReadlineAction(ReadlineAction(kind: rakInsertText, text: "a"))
    discard state.applyReadlineAction(ReadlineAction(kind: rakInsertText, text: "c"))
    discard state.applyReadlineAction(ReadlineAction(kind: rakMoveLeft))
    discard state.applyReadlineAction(ReadlineAction(kind: rakInsertText, text: "b"))
    check state.buffer == "abc"
    check state.cursor == 2

  test "readline backspace removes the character before the cursor":
    var state = initReadlineState("> ")
    discard state.applyReadlineAction(ReadlineAction(kind: rakInsertText, text: "abc"))
    discard state.applyReadlineAction(ReadlineAction(kind: rakMoveLeft))
    discard state.applyReadlineAction(ReadlineAction(kind: rakBackspace))
    check state.buffer == "ac"
    check state.cursor == 1

  test "readline history restores the current draft":
    var state = initReadlineState("> ", @["first", "second"])
    discard state.applyReadlineAction(ReadlineAction(kind: rakInsertText, text: "draft"))
    discard state.applyReadlineAction(ReadlineAction(kind: rakHistoryPrev))
    check state.buffer == "second"
    discard state.applyReadlineAction(ReadlineAction(kind: rakHistoryPrev))
    check state.buffer == "first"
    discard state.applyReadlineAction(ReadlineAction(kind: rakHistoryNext))
    check state.buffer == "second"
    discard state.applyReadlineAction(ReadlineAction(kind: rakHistoryNext))
    check state.buffer == "draft"
    check state.cursor == 5

  test "readline ctrl-l requests a clear and redraw":
    var state = initReadlineState("> ")
    let effect = state.applyReadlineAction(ReadlineAction(kind: rakClearScreen))
    check effect.clearScreen
    check effect.redraw
    check state.buffer == ""

  test "readline decodes unix arrow keys and ctrl-l":
    check decodeUnixReadlineSequence("\e[A").kind == rakHistoryPrev
    check decodeUnixReadlineSequence("\e[B").kind == rakHistoryNext
    check decodeUnixReadlineSequence("\e[C").kind == rakMoveRight
    check decodeUnixReadlineSequence("\e[D").kind == rakMoveLeft
    check decodeUnixReadlineSequence("\x0c").kind == rakClearScreen

  test "readline decodes windows arrow keys and ctrl-l":
    check decodeWindowsReadlineKey('\xe0', 'H').kind == rakHistoryPrev
    check decodeWindowsReadlineKey('\xe0', 'P').kind == rakHistoryNext
    check decodeWindowsReadlineKey('\xe0', 'M').kind == rakMoveRight
    check decodeWindowsReadlineKey('\xe0', 'K').kind == rakMoveLeft
    check decodeWindowsReadlineKey('\x0c').kind == rakClearScreen

  test "formats simple commands canonically":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use format global
format-source "+   1   2"
""")
    check value.kind == Text
    check value.textValue == "+ 1 2"

  test "formats blocks and preserves comments":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use format global
format-source "; lead
if T do
; inside
+   1   2 ; tail
end"
""")
    check value.kind == Text
    check value.textValue == """; lead
if T do
    ; inside
    + 1 2 ; tail
end"""

  test "formats multiline sequences with comments":
    let runtime = newTestRuntime()
    let value = runtime.evaluate("""
use format global
format-source "call #[
1
; item
2
]"
""")
    check value.kind == Text
    check value.textValue == """call #[
    1
    ; item
    2
]"""

  test "formats files":
    let runtime = newTestRuntime()
    let path = getTempDir() / "sushi-format-test.sushi"
    writeFile(path, "+   4   5")
    let value = runtime.evaluate("""
use format global
format-file """ & "\"" & path.replace("\\", "\\\\") & "\"" & """
""")
    check value.kind == Text
    check value.textValue == "+ 4 5"

  test "runs sushi through the dynamic library":
    buildDynamicLibrary()

    let library = loadLib(dynamicLibraryPath)
    require not library.isNil
    defer: unloadLib(library)

    let runtimeNew = loadSymbol[SushiRuntimeNewProc](library, "sushi_runtime_new")
    let runtimeNewWithArgs = loadSymbol[SushiRuntimeNewWithArgsProc](library, "sushi_runtime_new_with_args")
    let runtimeFree = loadSymbol[SushiRuntimeFreeProc](library, "sushi_runtime_free")
    let runtimeEval = loadSymbol[SushiRuntimeEvalProc](library, "sushi_runtime_eval")
    let runtimeEvalFile = loadSymbol[SushiRuntimeEvalFileProc](library, "sushi_runtime_eval_file")
    let stringFree = loadSymbol[SushiStringFreeProc](library, "sushi_string_free")

    let runtime = runtimeNew()
    require not runtime.isNil
    defer: runtimeFree(runtime)

    let directEval = callEval(runtimeEval, stringFree, runtime, "+ 40 2")
    check directEval.status == 0
    check directEval.text == "42"

    let scriptEval = callEval(runtimeEval, stringFree, runtime, """
fun answer [] do
  + 39 3
end
answer
""")
    check scriptEval.status == 0
    check scriptEval.text == "42"

    let scriptPath = getTempDir() / "sushi-dynlib-test.sushi"
    writeFile(scriptPath, "+ 20 22")
    let fileEval = callEvalFile(runtimeEvalFile, stringFree, runtime, scriptPath)
    check fileEval.status == 0
    check fileEval.text == "42"

    let runtimeWithArgs = runtimeNewWithArgs(0, nil)
    require not runtimeWithArgs.isNil
    defer: runtimeFree(runtimeWithArgs)

    let noArgEval = callEval(runtimeEval, stringFree, runtimeWithArgs, "+ 41 1")
    check noArgEval.status == 0
    check noArgEval.text == "42"

  test "runs the embedded cli without scripts on disk":
    buildBinary()
    let tempDir = getTempDir() / "sushi-embedded-cli-test"
    createDir(tempDir)
    let result = execCmdEx(binaryPath.quoteShell & " noop", workingDir = tempDir)
    check result.exitCode == 1
    check "Usage: sushi [--run <path>]" in result.output

  test "repl exposes the previous result through underscore":
    buildBinary()
    let result = runBinaryWithInput("+ 1 2\n+ _ 4\n:quit\n")
    let output = stripAnsi(result.output)
    check result.exitCode == 0
    check "Sushi REPL" in output
    check "> 3" in output
    check "> 7" in output
    check "bye" in output

  test "repl exposes the previous quoted form through underscore":
    buildBinary()
    let result = runBinaryWithInput("(1 + 2)\neval _\n:quit\n")
    let output = stripAnsi(result.output)
    check result.exitCode == 0
    check "Sushi REPL" in output
    check "> + 1 2" in output
    check "> 3" in output
    check "bye" in output

  test "repl keeps underscore after a failed command":
    buildBinary()
    let result = runBinaryWithInput("(1 + 2)\nunknown 1\neval _\n:quit\n")
    let output = stripAnsi(result.output)
    check result.exitCode == 0
    check "> + 1 2" in output
    check "Unknown command: unknown" in output
    check "> 3" in output
    check "bye" in output

  test "repl can eval underscore repeatedly":
    buildBinary()
    let result = runBinaryWithInput("(1 + 2)\neval _\neval _\n:quit\n")
    let output = stripAnsi(result.output)
    check result.exitCode == 0
    check "> + 1 2" in output
    check output.count("> 3") == 2
    check "bye" in output

  test "repl initializes underscore before the first command":
    buildBinary()
    let result = runBinaryWithInput("table \"v\" _\n:quit\n")
    let output = stripAnsi(result.output)
    check result.exitCode == 0
    check "{\"v\" }" in output
    check "bye" in output

  test "repl prints block results without re-executing them":
    buildBinary()
    let result = runBinaryWithInput("do 1 2 3 end\n+ 1 2\n:quit\n")
    let output = stripAnsi(result.output)
    check result.exitCode == 0
    check "commandKind head must be a symbol, got 1." notin output
    check "do" in output
    check "> 3" in output
    check "bye" in output
