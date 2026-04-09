import std/[colors, math, terminal]
import model
import runtime

proc render(value: Value): string =
  if value.kind == Text: value.textValue else: formatValue(value)

proc requireText(value: Value; commandName: string): string =
  if value.kind != Text:
    raise newException(ValueError, "'" & commandName & "' expects text.")
  value.textValue

proc requireInteger(value: Value; commandName: string): int =
  if value.kind != Integer:
    raise newException(ValueError, "'" & commandName & "' expects integers.")
  value.intValue

proc requireBoolean(value: Value; commandName: string): bool =
  if value.kind != Boolean:
    raise newException(ValueError, "'" & commandName & "' expects a boolean.")
  value.boolValue

proc buildIoModule*(): NativeModuleDefinition =
  var builder = initNativeModuleBuilder("io")
  discard builder.command("write", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let value = evaluator.evaluateQuoted(args[0], env)
    stdout.write(render(value))
    value)
  discard builder.command("write-line", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len == 0:
      echo ""
      return newText("")
    let value = evaluator.evaluateQuoted(args[0], env)
    echo render(value)
    value)
  discard builder.command("write-error", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let value = evaluator.evaluateQuoted(args[0], env)
    stderr.write(render(value))
    value)
  discard builder.command("write-error-line", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len == 0:
      stderr.writeLine("")
      return newText("")
    let value = evaluator.evaluateQuoted(args[0], env)
    stderr.writeLine(render(value))
    value)
  discard builder.command("read-line", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    discard evaluator
    discard env
    discard args
    try:
      newText(stdin.readLine())
    except EOFError:
      newBoolean(false))
  discard builder.command("clear", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    discard evaluator
    discard env
    discard args
    stdout.eraseScreen()
    stdout.setCursorPos(0, 0)
    newBoolean(true))
  discard builder.command("width", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    discard evaluator
    discard env
    discard args
    newInteger(terminalWidth()))
  discard builder.command("height", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    discard evaluator
    discard env
    discard args
    newInteger(terminalHeight()))
  discard builder.command("getch", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    discard evaluator
    discard env
    discard args
    newText($getch()))
  discard builder.command("set-cursor-visible", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let visible = requireBoolean(evaluator.evaluateQuoted(args[0], env), "set-cursor-visible")
    if visible:
      stdout.showCursor()
    else:
      stdout.hideCursor()
    newBoolean(true))
  discard builder.command("set-cursor", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let x = requireInteger(evaluator.evaluateQuoted(args[0], env), "set-cursor")
    let y = requireInteger(evaluator.evaluateQuoted(args[1], env), "set-cursor")
    stdout.setCursorPos(x, y)
    newBoolean(true))
  discard builder.command("set-fg", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let colorName = requireText(evaluator.evaluateQuoted(args[0], env), "set-fg")
    stdout.setForegroundColor(parseColor(colorName))
    newBoolean(true))
  discard builder.command("set-bg", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let colorName = requireText(evaluator.evaluateQuoted(args[0], env), "set-bg")
    stdout.setBackgroundColor(parseColor(colorName))
    newBoolean(true))
  discard builder.command("reset-color", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    discard evaluator
    discard env
    discard args
    stdout.resetAttributes()
    newBoolean(true))
  builder.build

proc buildBaseModule*(): NativeModuleDefinition =
  var builder = initNativeModuleBuilder("base")
  discard builder.command("binary-search", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let sequenceValue = evaluator.evaluateQuoted(args[0], env)
    let target = evaluator.evaluateQuoted(args[1], env)
    if sequenceValue.kind != Sequence:
      raise newException(ValueError, "Binary search expects a sequence")
    var lo = 0
    var hi = sequenceValue.items.len - 1
    while lo <= hi:
      let mid = (lo + hi) div 2
      let cmp =
        if sequenceValue.items[mid] == target: 0
        elif hash(sequenceValue.items[mid]) < hash(target): -1
        else: 1
      if cmp == 0:
        return newInteger(mid)
      if cmp < 0:
        lo = mid + 1
      else:
        hi = mid - 1
    newInteger(-(lo + 1)))
  discard builder.command("arity", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let arrayValue = evaluator.evaluateQuoted(args[0], env)
    if arrayValue.kind != Array:
      raise newException(ValueError, "'arity' expects an array.")
    newInteger(arrayValue.arity))
  builder.build

proc buildMathModule*(): NativeModuleDefinition =
  var builder = initNativeModuleBuilder("math")
  discard builder.command("clamp", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let a = evaluator.evaluateQuoted(args[0], env)
    let b = evaluator.evaluateQuoted(args[1], env)
    let c = evaluator.evaluateQuoted(args[2], env)
    case a.kind
    of Integer:
      if b.kind != Integer or c.kind != Integer:
        raise newException(ValueError, "Expected all integers.")
      newInteger(clamp(a.intValue, b.intValue, c.intValue))
    of Real:
      if b.kind != Real or c.kind != Real:
        raise newException(ValueError, "Expected all reals.")
      newReal(clamp(a.realValue, b.realValue, c.realValue))
    else:
      raise newException(ValueError, "Expected number."))
  discard builder.command("mod", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let left = evaluator.evaluateQuoted(args[0], env)
    let right = evaluator.evaluateQuoted(args[1], env)
    if left.kind != Integer or right.kind != Integer:
      raise newException(ValueError, "Expected number.")
    newInteger(left.intValue mod right.intValue))
  builder.build
