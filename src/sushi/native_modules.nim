import std/[colors, math, sequtils, strutils, tables, terminal, rdstdin]
when not defined(windows):
  import std/[posix, termios]
import diagnostics
import parser
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

proc put(entries: var Table[Value, Value]; key: string; value: Value) =
  entries[newText(key)] = value

proc newTableValue(pairs: openArray[(string, Value)]): Value =
  var entries = initTable[Value, Value]()
  for pair in pairs:
    entries.put(pair[0], pair[1])
  newTable(entries)

proc commentValue(comment: CommentTrivia): Value =
  newTableValue({
    "text": newText(comment.text),
    "start": newInteger(comment.span.start),
    "finish": newInteger(comment.span.finish),
    "has-code-before": newBoolean(comment.hasCodeBefore)
  })

proc commentListValue(comments: seq[CommentTrivia]): Value =
  newSequence(comments.mapIt(commentValue(it)))

proc spanEndLine(span: SourceSpan): int =
  if span.isEmpty:
    return 0
  let offset = if span.finish > span.start: span.finish - 1 else: span.start
  span.file.getLocation(offset).line

proc splitComments(comments: seq[CommentTrivia]; spans: seq[SourceSpan]):
    tuple[inside, leading, trailing: seq[seq[CommentTrivia]], suffix: seq[CommentTrivia]] =
  result.inside = newSeq[seq[CommentTrivia]](spans.len)
  result.leading = newSeq[seq[CommentTrivia]](spans.len)
  result.trailing = newSeq[seq[CommentTrivia]](spans.len)
  var outer: seq[CommentTrivia]

  for comment in comments:
    var assigned = false
    for i, span in spans:
      if not span.isEmpty and comment.span.start >= span.start and comment.span.finish <= span.finish:
        result.inside[i].add(comment)
        assigned = true
        break
    if not assigned:
      outer.add(comment)

  for comment in outer:
    var previous = -1
    var upcoming = -1
    for i, span in spans:
      if span.finish <= comment.span.start:
        previous = i
      elif upcoming < 0 and comment.span.finish <= span.start:
        upcoming = i
    if previous >= 0 and comment.span.startLocation.line == spanEndLine(spans[previous]):
      result.trailing[previous].add(comment)
    elif upcoming >= 0:
      result.leading[upcoming].add(comment)
    else:
      result.suffix.add(comment)

proc serializeNode(node: Value; comments: seq[CommentTrivia] = @[];
    leading: seq[CommentTrivia] = @[]; trailing: seq[CommentTrivia] = @[]): Value

proc baseNode(kind: string; node: Value; leading, trailing: seq[CommentTrivia]): Table[Value, Value] =
  result = initTable[Value, Value]()
  result.put("kind", newText(kind))
  result.put("render", newText(formatValue(node)))
  result.put("start", newInteger(node.span.start))
  result.put("finish", newInteger(node.span.finish))
  result.put("leading-comments", commentListValue(leading))
  result.put("trailing-comments", commentListValue(trailing))

proc serializeEntry(keyNode, valueNode: Value; span: SourceSpan;
    leading, trailing: seq[CommentTrivia]): Value =
  var entries = initTable[Value, Value]()
  entries.put("kind", newText("entry"))
  entries.put("render", newText(formatValue(keyNode) & " " & formatValue(valueNode)))
  entries.put("start", newInteger(span.start))
  entries.put("finish", newInteger(span.finish))
  entries.put("leading-comments", commentListValue(leading))
  entries.put("trailing-comments", commentListValue(trailing))
  entries.put("key", serializeNode(keyNode))
  entries.put("value", serializeNode(valueNode))
  newTable(entries)

proc serializeNode(node: Value; comments: seq[CommentTrivia] = @[];
    leading: seq[CommentTrivia] = @[]; trailing: seq[CommentTrivia] = @[]): Value =
  if node.isNil:
    return newNilValue()

  case node.kind
  of Script:
    var entries = baseNode("script", node, leading, trailing)
    let spans = node.commands.mapIt(it.span)
    let attached = splitComments(comments, spans)
    entries.put("suffix-comments", commentListValue(attached.suffix))
    var commands: seq[Value]
    for i, command in node.commands:
      commands.add(serializeNode(command, attached.inside[i], attached.leading[i], attached.trailing[i]))
    entries.put("commands", newSequence(commands))
    newTable(entries)
  of Block:
    var entries = baseNode("block", node, leading, trailing)
    let spans = node.blockCommands.mapIt(it.span)
    let attached = splitComments(comments, spans)
    entries.put("suffix-comments", commentListValue(attached.suffix))
    var commands: seq[Value]
    for i, command in node.blockCommands:
      commands.add(serializeNode(command, attached.inside[i], attached.leading[i], attached.trailing[i]))
    entries.put("commands", newSequence(commands))
    newTable(entries)
  of Command:
    var entries = baseNode("command", node, leading, trailing)
    let spans = node.objects.mapIt(it.span)
    let attached = splitComments(comments, spans)
    var objects: seq[Value]
    for i, obj in node.objects:
      objects.add(serializeNode(obj, attached.inside[i], attached.leading[i], attached.trailing[i]))
    entries.put("objects", newSequence(objects))
    newTable(entries)
  of Sequence:
    var entries = baseNode("sequence", node, leading, trailing)
    let spans = node.items.mapIt(it.span)
    let attached = splitComments(comments, spans)
    entries.put("suffix-comments", commentListValue(attached.suffix))
    var items: seq[Value]
    for i, item in node.items:
      items.add(serializeNode(item, attached.inside[i], attached.leading[i], attached.trailing[i]))
    entries.put("items", newSequence(items))
    newTable(entries)
  of Table:
    var entries = baseNode("table", node, leading, trailing)
    var keys: seq[Value]
    var values: seq[Value]
    var spans: seq[SourceSpan]
    for key, value in node.entries.pairs:
      keys.add(key)
      values.add(value)
      spans.add(cover(key.span, value.span))
    let attached = splitComments(comments, spans)
    var entryValues: seq[Value]
    for i in 0 ..< keys.len:
      entryValues.add(serializeEntry(keys[i], values[i], spans[i], attached.leading[i], attached.trailing[i]))
    entries.put("suffix-comments", commentListValue(attached.suffix))
    entries.put("entries", newSequence(entryValues))
    newTable(entries)
  of MemberAccess:
    var entries = baseNode("member-access", node, leading, trailing)
    entries.put("receiver", serializeNode(node.receiver))
    entries.put("member-name", newText(node.memberName))
    newTable(entries)
  of IndexedAccess:
    var entries = baseNode("indexed-access", node, leading, trailing)
    entries.put("receiver", serializeNode(node.indexedReceiver))
    entries.put("index", serializeNode(node.indexValue))
    newTable(entries)
  of StringTemplate:
    var entries = baseNode("string-template", node, leading, trailing)
    var segments: seq[Value]
    for segment in node.templateSegments:
      case segment.kind
      of Text:
        segments.add(newTableValue({
          "kind": newText("text"),
          "text": newText(segment.text)
        }))
      of Object:
        segments.add(newTableValue({
          "kind": newText("object"),
          "object": serializeNode(segment.obj)
        }))
    entries.put("segments", newSequence(segments))
    newTable(entries)
  of Symbol:
    newTableValue({
      "kind": newText("symbol"),
      "render": newText(formatValue(node)),
      "text": newText(node.symbolValue),
      "start": newInteger(node.span.start),
      "finish": newInteger(node.span.finish),
      "leading-comments": commentListValue(leading),
      "trailing-comments": commentListValue(trailing)
    })
  of Text:
    newTableValue({
      "kind": newText("text"),
      "render": newText(formatValue(node)),
      "text": newText(node.textValue),
      "start": newInteger(node.span.start),
      "finish": newInteger(node.span.finish),
      "leading-comments": commentListValue(leading),
      "trailing-comments": commentListValue(trailing)
    })
  of Integer, Real, Boolean:
    var entries = baseNode(
      if node.kind == Integer: "integer" elif node.kind == Real: "real" else: "boolean",
      node, leading, trailing)
    entries.put("text", newText(formatValue(node)))
    newTable(entries)
  else:
    var entries = baseNode($node.kind, node, leading, trailing)
    newTable(entries)

proc dropLastByte(text: string): string =
  if text.len == 0:
    return text
  result = text
  result.setLen(result.len - 1)

proc readKeySequence(): Value =
  when defined(windows):
    newText($getch())
  else:
    let fd = stdin.getFileHandle()
    if fd.isatty() == 0:
      var ch: char
      if readBuffer(stdin, addr ch, 1) > 0:
        newText($ch)
      else:
        newText("")
    else:
      var oldMode, rawMode: Termios
      discard fd.tcGetAttr(addr oldMode)
      rawMode = oldMode
      rawMode.c_iflag = rawMode.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
      rawMode.c_oflag = rawMode.c_oflag and not Cflag(OPOST)
      rawMode.c_cflag = (rawMode.c_cflag and not Cflag(CSIZE or PARENB)) or CS8
      rawMode.c_lflag = rawMode.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
      rawMode.c_cc[VMIN] = char(0)
      rawMode.c_cc[VTIME] = char(1)
      discard fd.tcSetAttr(TCSAFLUSH, addr rawMode)
      try:
        var ch: char
        var sequence = ""
        while true:
          let count = readBuffer(stdin, addr ch, 1)
          if count <= 0:
            break
          sequence.add(ch)
          if ch != '\e' and (sequence.len == 1 or sequence[^1] != '\e'):
            break
          if sequence.len > 1 and sequence[0] == '\e' and not (count > 0 and (ch == '[' or (ch >= '0' and ch <= '9'))):
            break
        if sequence.len == 0:
          newText("")
        else:
          newText(sequence)
      finally:
        discard fd.tcSetAttr(TCSADRAIN, addr oldMode)

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
  discard builder.command("concat", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    var buffer = ""
    for arg in args:
      buffer.add(requireText(evaluator.evaluateQuoted(arg, env), "concat"))
    newText(buffer))
  discard builder.command("repeat", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let text = requireText(evaluator.evaluateQuoted(args[0], env), "repeat")
    let count = requireInteger(evaluator.evaluateQuoted(args[1], env), "repeat")
    if count < 0:
      raise newException(ValueError, "'repeat' expects a non-negative count.")
    newText(strutils.repeat(text, count)))
  discard builder.command("contains", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let text = requireText(evaluator.evaluateQuoted(args[0], env), "contains")
    let needle = requireText(evaluator.evaluateQuoted(args[1], env), "contains")
    newBoolean(text.contains(needle)))
  discard builder.command("read-line", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    discard evaluator
    discard env
    discard args
    try:
      newText(readLineFromStdin(""))
    except EOFError:
      newBoolean(false))
  discard builder.command("read-file", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let path = requireText(evaluator.evaluateQuoted(args[0], env), "read-file")
    newText(readFile(path)))
  discard builder.command("write-file", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let path = requireText(evaluator.evaluateQuoted(args[0], env), "write-file")
    let text = requireText(evaluator.evaluateQuoted(args[1], env), "write-file")
    writeFile(path, text)
    newBoolean(true))
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
  discard builder.command("read-key-sequence", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    discard evaluator
    discard env
    discard args
    readKeySequence())
  discard builder.command("char", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let code = requireInteger(evaluator.evaluateQuoted(args[0], env), "char")
    if code < 0 or code > 255:
      raise newException(ValueError, "'char' expects a byte value between 0 and 255.")
    newText($chr(code)))
  discard builder.command("drop-last", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let text = requireText(evaluator.evaluateQuoted(args[0], env), "drop-last")
    newText(dropLastByte(text)))
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

proc buildSyntaxModule*(): NativeModuleDefinition =
  var builder = initNativeModuleBuilder("syntax")
  discard builder.command("parse-source", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let sourceText = requireText(evaluator.evaluateQuoted(args[0], env), "parse-source")
    let sourceName =
      if args.len > 1:
        requireText(evaluator.evaluateQuoted(args[1], env), "parse-source")
      else:
        "<format>"
    let source = newSourceFile(sourceName, sourceText)
    let ast = parseScript(source)
    let comments = scanComments(source)
    serializeNode(ast, comments))
  discard builder.command("field", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 2:
      raise newException(ValueError, "'field' expects a table and a text key.")
    var tableValue = evaluator.evaluateQuoted(args[0], env)
    while tableValue.kind == CapturedSyntax:
      tableValue = evaluator.evaluateQuoted(tableValue.capturedValue, tableValue.capturedEnv)
    if tableValue.kind != Table:
      raise newException(ValueError, "'field' expects a table as its first argument, got " & $tableValue.kind & ".")
    let key = newText(requireText(evaluator.evaluateQuoted(args[1], env), "field"))
    if not tableValue.entries.hasKey(key):
      return newNilValue()
    tableValue.entries[key])
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
