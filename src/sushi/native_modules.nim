import std/[algorithm, colors, locks, math, net, os, sequtils, strutils, tables, terminal, times]
when defined(windows):
  import std/winlean
  proc getConsoleMode(hConsoleHandle: Handle; dwMode: ptr DWORD): WINBOOL {.
      stdcall, dynlib: "kernel32", importc: "GetConsoleMode".}
else:
  import std/[posix, termios]
import diagnostics
import builtin_scripts
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

proc requireSymbol(value: Value; commandName: string): string =
  if value.kind != Symbol:
    raise newException(ValueError, "'" & commandName & "' expects a symbol.")
  value.symbolValue

proc requireBoolean(value: Value; commandName: string): bool =
  if value.kind != Boolean:
    raise newException(ValueError, "'" & commandName & "' expects a boolean.")
  value.boolValue

proc requireTable(value: Value; commandName: string): Value =
  if value.kind != Table:
    raise newException(ValueError, "'" & commandName & "' expects a table.")
  value

proc requireSequence(value: Value; commandName: string): Value =
  if value.kind != Sequence:
    raise newException(ValueError, "'" & commandName & "' expects a list.")
  value

type
  ScriptDoc = object
    moduleName: string
    kind: string
    name: string
    signature: string
    docString: string

proc moduleDisplayName(sourceName: string): string =
  if sourceName.startsWith("<builtin:") and sourceName.endsWith(">"):
    return sourceName["<builtin:".len ..< sourceName.len - 1].changeFileExt("")
  splitFile(sourceName).name

proc cleanDocComment(text: string): string =
  result = if text.len <= 3: "" else: text[3 .. ^1]
  if result.startsWith(" "):
    result = result[1 .. ^1]

proc leadingDocString(command: Value; comments: seq[CommentTrivia]): string =
  if command.span.isEmpty:
    return ""
  var lines: seq[string]
  var expectedLine = command.span.startLocation.line - 1
  if expectedLine < 1:
    return ""
  for i in countdown(comments.high, 0):
    let comment = comments[i]
    if comment.span.finish > command.span.start:
      continue
    let line = comment.span.startLocation.line
    if line != expectedLine:
      break
    if comment.hasCodeBefore or not comment.text.startsWith(";;;"):
      return ""
    lines.add(cleanDocComment(comment.text))
    dec expectedLine
  lines.reverse()
  lines.join("\n").strip()

proc commandSignature(command: Value): string =
  if command.kind != Command:
    return ""
  let objects =
    if command.objects.len > 0 and command.objects[^1].kind == Block:
      command.objects[0 ..< command.objects.high]
    else:
      command.objects
  objects.mapIt(formatValue(it)).join(" ")

proc declarationDoc(command: Value; moduleName: string; comments: seq[CommentTrivia]): ScriptDoc =
  if command.kind != Command or command.objects.len < 2 or command.objects[0].kind != Symbol:
    return
  let head = command.objects[0].symbolValue
  if head notin ["fun", "class", "var"] or command.objects[1].kind != Symbol:
    return
  let docString = leadingDocString(command, comments)
  if docString.len == 0:
    return
  ScriptDoc(
    moduleName: moduleName,
    kind: head,
    name: command.objects[1].symbolValue,
    signature: commandSignature(command),
    docString: docString
  )

proc collectScriptDocs(): seq[ScriptDoc] =
  for script in embeddedScripts():
    let source = newSourceFile(script.sourceName, script.source)
    let ast = parseScript(source)
    let comments = scanComments(source)
    let moduleName = moduleDisplayName(script.sourceName)
    for command in ast.commands:
      let doc = declarationDoc(command, moduleName, comments)
      if doc.docString.len > 0:
        result.add(doc)

proc htmlEscape(text: string): string =
  for ch in text:
    case ch
    of '&':
      result.add("&amp;")
    of '<':
      result.add("&lt;")
    of '>':
      result.add("&gt;")
    of '"':
      result.add("&quot;")
    of '\'':
      result.add("&#39;")
    else:
      result.add(ch)

proc paragraphHtml(text: string): string =
  var paragraphs: seq[string]
  for part in text.split("\n\n"):
    let trimmed = part.strip()
    if trimmed.len > 0:
      paragraphs.add("<p>" & htmlEscape(trimmed).replace("\n", "<br>") & "</p>")
  paragraphs.join("\n")

proc nativeDocFallback(moduleName, name: string): string =
  case moduleName & "." & name
  of "io.write": "Writes one or more values to standard output without adding newlines."
  of "io.write-line": "Writes one or more values to standard output, each followed by a newline."
  of "io.write-error": "Writes a value to standard error without adding a newline."
  of "io.write-error-line": "Writes one or more values to standard error, each followed by a newline."
  of "io.concat": "Concatenates any number of text values."
  of "io.repeat": "Repeats a text value a non-negative number of times."
  of "io.contains": "Returns true when text contains the requested substring."
  of "io.read-line": "Reads one line from standard input, or false at end of input."
  of "io.readline": "Reads one line with an optional prompt and interactive line-editing support."
  of "io.readline-history-add": "Adds an entry to the interactive readline history."
  of "io.read-file": "Reads an entire file as text."
  of "io.write-file": "Writes text to a file, replacing its contents."
  of "io.file-info": "Returns file metadata such as `:last-updated`."
  of "io.sleep": "Sleeps for a non-negative number of seconds."
  of "io.clear": "Clears the terminal and moves the cursor home."
  of "io.width": "Returns the terminal width in columns."
  of "io.height": "Returns the terminal height in rows."
  of "io.getch": "Reads one character from the terminal."
  of "io.read-key-sequence": "Reads a raw terminal key sequence."
  of "io.char": "Converts a byte-sized integer to a one-character text value."
  of "io.drop-last": "Drops the final byte from a text value."
  of "io.set-cursor-visible": "Shows or hides the terminal cursor."
  of "io.set-cursor": "Moves the terminal cursor to an x/y position."
  of "io.set-fg": "Sets the terminal foreground color by name."
  of "io.set-bg": "Sets the terminal background color by name."
  of "io.reset-color": "Resets terminal colors and attributes."
  of "http.sse-start": "Starts a local server-sent events endpoint and returns its connection details."
  of "http.sse-publish": "Publishes an event and data payload to clients connected to an SSE endpoint."
  of "http.sse-stop": "Stops a local server-sent events endpoint."
  of "syntax.parse-source": "Parses Sushi source text into a serialized syntax tree with comments."
  of "syntax.serialize": "Serializes a Sushi value into an AST node table."
  of "syntax.text": "Extracts text from a serialized symbol AST node."
  of "syntax.symbol": "Builds a serialized symbol AST node from text."
  of "syntax.command": "Builds a serialized command AST node from serialized objects."
  of "syntax.block": "Builds a serialized block AST node from serialized commands."
  of "syntax.eval-node": "Evaluates a serialized AST node, optionally using another captured scope."
  of "syntax.field": "Returns a text-keyed table field, or nil when the field is absent."
  of "base.binary-search": "Performs a binary search over a sorted Sushi list and returns the found index or insertion marker."
  of "base.arity": "Returns the arity, or remaining dimensionality, of an array."
  of "math.clamp": "Clamps an integer or real value between inclusive bounds of the same type."
  of "math.mod": "Returns the integer remainder of left divided by right."
  of "docs.generate-html": "Generates a standalone HTML reference page for native modules, core commands, and documented Sushi scripts."
  else: ""

proc nativeDocString(moduleName, name: string; value: Value): string =
  case value.kind
  of NativeCommand:
    if value.nativeCommand.docString.len > 0: value.nativeCommand.docString else: nativeDocFallback(moduleName, name)
  else:
    if value.docString.len > 0: value.docString else: nativeDocFallback(moduleName, name)

proc nativeSignatureFallback(moduleName, name: string): string =
  case moduleName & "." & name
  of "io.write": "io.write values..."
  of "io.write-line": "io.write-line [values...]"
  of "io.write-error": "io.write-error value"
  of "io.write-error-line": "io.write-error-line [values...]"
  of "io.concat": "io.concat text..."
  of "io.repeat": "io.repeat text count"
  of "io.contains": "io.contains text needle"
  of "io.read-line": "io.read-line"
  of "io.readline": "io.readline [prompt]"
  of "io.readline-history-add": "io.readline-history-add entry"
  of "io.read-file": "io.read-file path"
  of "io.write-file": "io.write-file path text"
  of "io.file-info": "io.file-info kind path"
  of "io.sleep": "io.sleep seconds"
  of "io.clear": "io.clear"
  of "io.width": "io.width"
  of "io.height": "io.height"
  of "io.getch": "io.getch"
  of "io.read-key-sequence": "io.read-key-sequence"
  of "io.char": "io.char code"
  of "io.drop-last": "io.drop-last text"
  of "io.set-cursor-visible": "io.set-cursor-visible visible"
  of "io.set-cursor": "io.set-cursor x y"
  of "io.set-fg": "io.set-fg color-name"
  of "io.set-bg": "io.set-bg color-name"
  of "io.reset-color": "io.reset-color"
  of "http.sse-start": "http.sse-start path"
  of "http.sse-publish": "http.sse-publish path event-name data"
  of "http.sse-stop": "http.sse-stop path"
  of "syntax.parse-source": "syntax.parse-source source [source-name]"
  of "syntax.serialize": "syntax.serialize value"
  of "syntax.text": "syntax.text symbol-node"
  of "syntax.symbol": "syntax.symbol text"
  of "syntax.command": "syntax.command objects"
  of "syntax.block": "syntax.block commands"
  of "syntax.eval-node": "syntax.eval-node node [scope]"
  of "syntax.field": "syntax.field table key"
  of "base.binary-search": "base.binary-search list target"
  of "base.arity": "base.arity array"
  of "math.clamp": "math.clamp value min max"
  of "math.mod": "math.mod left right"
  of "docs.generate-html": "docs.generate-html output-path"
  else: name

proc nativeSignature(moduleName, name: string; value: Value): string =
  case value.kind
  of NativeCommand:
    if value.nativeCommand.signature.len > 0 and (moduleName == "core" or value.nativeCommand.signature != name):
      value.nativeCommand.signature
    else:
      nativeSignatureFallback(moduleName, name)
  else:
    if moduleName.len > 0: moduleName & "." & name else: name

proc renderDocPage*(env: Env): string =
  var htmlText = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sushi Standard Library</title>
<style>
:root { color-scheme: light; --ink: #1f2933; --muted: #607080; --line: #d7dde5; --panel: #f7f9fb; --accent: #0f766e; }
body { margin: 0; font: 16px/1.5 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--ink); background: #fff; }
header { padding: 48px max(24px, calc((100vw - 1120px) / 2)) 28px; border-bottom: 1px solid var(--line); background: linear-gradient(180deg, #f8fbfb 0%, #fff 100%); }
main { max-width: 1120px; margin: 0 auto; padding: 28px 24px 64px; }
h1 { margin: 0 0 8px; font-size: 40px; line-height: 1.1; }
h2 { margin: 36px 0 14px; padding-bottom: 8px; border-bottom: 1px solid var(--line); font-size: 24px; }
h3 { margin: 0; font-size: 18px; }
p { margin: 8px 0 0; color: var(--muted); }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; }
.entry { border: 1px solid var(--line); border-radius: 8px; padding: 14px 16px; background: var(--panel); }
.signature { margin-top: 6px; font: 14px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: var(--accent); overflow-wrap: anywhere; }
.kind { color: var(--muted); font-size: 13px; text-transform: uppercase; letter-spacing: .04em; }
nav { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 20px; }
nav a { color: var(--accent); text-decoration: none; border: 1px solid var(--line); border-radius: 999px; padding: 4px 10px; background: #fff; }
</style>
</head>
<body>
<header>
<h1>Sushi Standard Library</h1>
<p>Native modules, core commands, and documented Sushi library exports.</p>
<nav>"""

  if not env.isNil and not env.runtimeState.isNil:
    htmlText.add """<a href="#core">Core</a>"""
    for moduleName, _ in env.runtimeState.nativeModulesByName.pairs:
      htmlText.add "<a href=\"#" & htmlEscape(moduleName) & "\">" & htmlEscape(moduleName) & "</a>"
  htmlText.add """<a href="#scripts">Scripts</a></nav></header><main>"""

  if not env.isNil and not env.runtimeState.isNil and not env.runtimeState.rootEnv.isNil:
    htmlText.add """<section id="core"><h2>Core</h2><div class="grid">"""
    for name, value in env.runtimeState.rootEnv.bindings.pairs:
      if value.kind == NativeCommand:
        htmlText.add "<article class=\"entry\"><div class=\"kind\">native command</div><h3>" & htmlEscape(name) &
          "</h3><div class=\"signature\">" & htmlEscape(nativeSignature("core", name, value)) & "</div>" &
          paragraphHtml(nativeDocString("core", name, value)) & "</article>"
    htmlText.add "</div></section>"

    for moduleName, moduleValue in env.runtimeState.nativeModulesByName.pairs:
      htmlText.add "<section id=\"" & htmlEscape(moduleName) & "\"><h2>" & htmlEscape(moduleName) & "</h2><div class=\"grid\">"
      for name, value in moduleValue.exports.pairs:
        let kind = if value.kind == NativeCommand: "native command" else: "native value"
        htmlText.add "<article class=\"entry\"><div class=\"kind\">" & kind & "</div><h3>" & htmlEscape(name) &
          "</h3><div class=\"signature\">" & htmlEscape(nativeSignature(moduleName, name, value)) & "</div>" &
          paragraphHtml(nativeDocString(moduleName, name, value)) & "</article>"
      htmlText.add "</div></section>"

  let scriptDocs = collectScriptDocs()
  htmlText.add """<section id="scripts"><h2>Scripts</h2>"""
  var currentModule = ""
  var opened = false
  for doc in scriptDocs:
    if doc.moduleName != currentModule:
      if opened:
        htmlText.add "</div>"
      currentModule = doc.moduleName
      htmlText.add "<h2>" & htmlEscape(currentModule) & "</h2><div class=\"grid\">"
      opened = true
    htmlText.add "<article class=\"entry\"><div class=\"kind\">" & htmlEscape(doc.kind) & "</div><h3>" &
      htmlEscape(doc.name) & "</h3><div class=\"signature\">" & htmlEscape(doc.signature) & "</div>" &
      paragraphHtml(doc.docString) & "</article>"
  if opened:
    htmlText.add "</div>"
  htmlText.add "</section></main></body></html>"
  htmlText

type
  SseServerState = ref object
    path: string
    port: Port
    server: Socket
    clients: seq[Socket]
    running: bool
    lock: Lock
    thread: Thread[pointer]

var
  sseRegistryLock: Lock
  sseRegistryInitialized = false
  sseServers: Table[string, SseServerState]

proc ensureSseRegistry() =
  if sseRegistryInitialized:
    return
  initLock(sseRegistryLock)
  sseServers = initTable[string, SseServerState]()
  sseRegistryInitialized = true

proc isServerRunning(state: SseServerState): bool =
  acquire(state.lock)
  try:
    result = state.running
  finally:
    release(state.lock)

proc setServerRunning(state: SseServerState; value: bool) =
  acquire(state.lock)
  try:
    state.running = value
  finally:
    release(state.lock)

proc closeSocketQuietly(socket: Socket) =
  try:
    socket.close()
  except CatchableError:
    discard

proc readHttpRequestPath(client: Socket): string =
  var request = ""
  while "\r\n\r\n" notin request and request.len < 16384:
    let chunk = client.recv(1024)
    if chunk.len == 0:
      break
    request.add(chunk)
  if request.len == 0:
    return ""
  let lines = request.split("\r\n")
  if lines.len == 0:
    return ""
  let parts = lines[0].split(" ")
  if parts.len < 2:
    return ""
  parts[1]

proc sseDataLines(data: string): string =
  let normalized = data.replace("\r\n", "\n").replace('\r', '\n')
  let lines = normalized.split('\n')
  result = lines.join("\r\ndata: ")

proc writeSseResponse(client: Socket) =
  client.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: text/event-stream\r\n" &
    "Cache-Control: no-cache\r\n" &
    "Connection: keep-alive\r\n" &
    "Access-Control-Allow-Origin: *\r\n" &
    "\r\n" &
    ": connected\r\n\r\n")

proc writeNotFound(client: Socket) =
  client.send(
    "HTTP/1.1 404 Not Found\r\n" &
    "Content-Type: text/plain\r\n" &
    "Connection: close\r\n" &
    "\r\n" &
    "not found")

proc sseServerThread(rawState: pointer) {.thread.} =
  let state = cast[SseServerState](rawState)
  while true:
    var client = newSocket(buffered = false)
    try:
      state.server.accept(client)
    except CatchableError:
      client.closeSocketQuietly()
      if not state.isServerRunning():
        break
      continue

    if not state.isServerRunning():
      client.closeSocketQuietly()
      break

    let requestPath = client.readHttpRequestPath()
    if requestPath != state.path:
      try:
        client.writeNotFound()
      except CatchableError:
        discard
      client.closeSocketQuietly()
      continue

    try:
      client.writeSseResponse()
      acquire(state.lock)
      try:
        state.clients.add(client)
      finally:
        release(state.lock)
    except CatchableError:
      client.closeSocketQuietly()

  state.server.closeSocketQuietly()
  acquire(state.lock)
  try:
    for client in state.clients:
      client.closeSocketQuietly()
    state.clients.setLen(0)
  finally:
    release(state.lock)

proc startSseServer(path: string): SseServerState =
  ensureSseRegistry()
  acquire(sseRegistryLock)
  try:
    if sseServers.hasKey(path):
      raise newException(ValueError, "An SSE server is already running for '" & path & "'.")
  finally:
    release(sseRegistryLock)

  let server = newSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let (_, port) = server.getLocalAddr()
  result = SseServerState(path: path, port: port, server: server, clients: @[], running: true)
  initLock(result.lock)
  createThread(result.thread, sseServerThread, cast[pointer](result))

  acquire(sseRegistryLock)
  try:
    sseServers[path] = result
  finally:
    release(sseRegistryLock)

proc findSseServer(path: string): SseServerState =
  ensureSseRegistry()
  acquire(sseRegistryLock)
  try:
    if sseServers.hasKey(path):
      result = sseServers[path]
  finally:
    release(sseRegistryLock)

proc wakeSseServer(state: SseServerState) =
  try:
    let wake = newSocket(buffered = false)
    wake.connect("127.0.0.1", state.port)
    wake.closeSocketQuietly()
  except CatchableError:
    discard

proc stopSseServer(path: string): bool =
  let state = findSseServer(path)
  if state.isNil:
    return false

  acquire(sseRegistryLock)
  try:
    if sseServers.hasKey(path):
      sseServers.del(path)
  finally:
    release(sseRegistryLock)

  state.setServerRunning(false)
  state.wakeSseServer()
  joinThread(state.thread)
  deinitLock(state.lock)
  true

proc publishSseEvent(path, eventName, data: string): bool =
  let state = findSseServer(path)
  if state.isNil:
    return false

  let payload = "event: " & eventName & "\r\n" &
    "data: " & sseDataLines(data) & "\r\n\r\n"

  acquire(state.lock)
  try:
    var index = 0
    while index < state.clients.len:
      let client = state.clients[index]
      try:
        client.send(payload)
        inc(index)
      except CatchableError:
        client.closeSocketQuietly()
        state.clients.delete(index)
  finally:
    release(state.lock)
  true

proc put(entries: var Table[Value, Value]; key: string; value: Value) =
  entries[newText(key)] = value

proc newTableValue(pairs: openArray[(string, Value)]): Value =
  var entries = initTable[Value, Value]()
  for pair in pairs:
    entries.put(pair[0], pair[1])
  newTable(entries)

proc getField(tableValue: Value; key, commandName: string): Value =
  let tableNode = requireTable(tableValue, commandName)
  let fieldKey = newText(key)
  if not tableNode.entries.hasKey(fieldKey):
    raise newException(ValueError, "'" & commandName & "' is missing required field '" & key & "'.")
  tableNode.entries[fieldKey]

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

proc deserializeNode(node: Value): Value

proc deserializeNodes(value: Value; fieldName, commandName: string): seq[Value] =
  let items = requireSequence(getField(value, fieldName, commandName), commandName)
  for item in items.items:
    result.add(deserializeNode(item))

proc deserializeTemplateSegments(value: Value; commandName: string): seq[StringTemplateSegment] =
  let items = requireSequence(getField(value, "segments", commandName), commandName)
  for item in items.items:
    let segment = requireTable(item, commandName)
    let kind = requireText(getField(segment, "kind", commandName), commandName)
    case kind
    of "text":
      result.add(StringTemplateSegment(kind: Text, text: requireText(getField(segment, "text", commandName), commandName)))
    of "object":
      result.add(StringTemplateSegment(kind: Object, obj: deserializeNode(getField(segment, "object", commandName))))
    else:
      raise newException(ValueError, "'" & commandName & "' does not support string template segment kind '" & kind & "'.")

proc deserializeTableEntries(value: Value; commandName: string): Table[Value, Value] =
  let items = requireSequence(getField(value, "entries", commandName), commandName)
  result = initTable[Value, Value]()
  for item in items.items:
    let entry = requireTable(item, commandName)
    let kind = requireText(getField(entry, "kind", commandName), commandName)
    if kind != "entry":
      raise newException(ValueError, "'" & commandName & "' expects table entries with kind 'entry'.")
    result[deserializeNode(getField(entry, "key", commandName))] = deserializeNode(getField(entry, "value", commandName))

proc deserializeNode(node: Value): Value =
  let commandName = "eval-node"
  let tableNode = requireTable(node, commandName)
  let kind = requireText(getField(tableNode, "kind", commandName), commandName)
  case kind
  of "script":
    newScript(deserializeNodes(tableNode, "commands", commandName))
  of "block":
    newBlock(deserializeNodes(tableNode, "commands", commandName))
  of "command":
    newCommand(deserializeNodes(tableNode, "objects", commandName))
  of "sequence":
    newSequence(deserializeNodes(tableNode, "items", commandName))
  of "table":
    newTable(deserializeTableEntries(tableNode, commandName))
  of "string-template":
    newStringTemplate(deserializeTemplateSegments(tableNode, commandName))
  of "symbol":
    newSymbol(requireText(getField(tableNode, "text", commandName), commandName))
  of "text":
    newText(requireText(getField(tableNode, "text", commandName), commandName))
  of "integer":
    newInteger(parseInt(requireText(getField(tableNode, "text", commandName), commandName)))
  of "real":
    newReal(parseFloat(requireText(getField(tableNode, "text", commandName), commandName)))
  of "boolean":
    newBoolean(requireText(getField(tableNode, "text", commandName), commandName) == "T")
  else:
    raise newException(ValueError, "'eval-node' does not support AST node kind '" & kind & "'.")

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

type
  ReadlineActionKind* = enum
    rakNone,
    rakInsertText,
    rakMoveLeft,
    rakMoveRight,
    rakHistoryPrev,
    rakHistoryNext,
    rakBackspace,
    rakClearScreen,
    rakSubmit,
    rakEof

  ReadlineAction* = object
    kind*: ReadlineActionKind
    text*: string

  ReadlineState* = object
    prompt*: string
    buffer*: string
    cursor*: int
    history*: seq[string]
    historyIndex*: int
    draft*: string

  ReadlineEffect* = object
    redraw*: bool
    clearScreen*: bool
    submit*: bool
    eof*: bool

var readlineHistory*: seq[string] = @[]

proc initReadlineState*(prompt: string; history: seq[string] = @[]): ReadlineState =
  ReadlineState(
    prompt: prompt,
    buffer: "",
    cursor: 0,
    history: history,
    historyIndex: history.len,
    draft: ""
  )

proc action(kind: ReadlineActionKind; text = ""): ReadlineAction =
  ReadlineAction(kind: kind, text: text)

proc insertAt(text: string; index: int; fragment: string): string =
  let safeIndex = max(0, min(index, text.len))
  let prefix =
    if safeIndex > 0:
      text[0 ..< safeIndex]
    else:
      ""
  let suffix =
    if safeIndex < text.len:
      text[safeIndex .. ^1]
    else:
      ""
  prefix & fragment & suffix

proc removeAt(text: string; index: int): string =
  if index < 0 or index >= text.len:
    return text
  let prefix =
    if index > 0:
      text[0 ..< index]
    else:
      ""
  let suffix =
    if index + 1 < text.len:
      text[(index + 1) .. ^1]
    else:
      ""
  prefix & suffix

proc applyReadlineAction*(state: var ReadlineState; event: ReadlineAction): ReadlineEffect =
  case event.kind
  of rakInsertText:
    if event.text.len > 0:
      state.buffer = insertAt(state.buffer, state.cursor, event.text)
      inc(state.cursor, event.text.len)
      result.redraw = true
  of rakMoveLeft:
    if state.cursor > 0:
      dec(state.cursor)
      result.redraw = true
  of rakMoveRight:
    if state.cursor < state.buffer.len:
      inc(state.cursor)
      result.redraw = true
  of rakHistoryPrev:
    if state.history.len > 0 and state.historyIndex > 0:
      if state.historyIndex == state.history.len:
        state.draft = state.buffer
      dec(state.historyIndex)
      state.buffer = state.history[state.historyIndex]
      state.cursor = state.buffer.len
      result.redraw = true
  of rakHistoryNext:
    if state.historyIndex < state.history.len:
      inc(state.historyIndex)
      if state.historyIndex == state.history.len:
        state.buffer = state.draft
      else:
        state.buffer = state.history[state.historyIndex]
      state.cursor = state.buffer.len
      result.redraw = true
  of rakBackspace:
    if state.cursor > 0:
      dec(state.cursor)
      state.buffer = removeAt(state.buffer, state.cursor)
      result.redraw = true
  of rakClearScreen:
    result.clearScreen = true
    result.redraw = true
  of rakSubmit:
    result.submit = true
  of rakEof:
    result.eof = true
  of rakNone:
    discard

proc decodeUnixReadlineSequence*(sequence: string): ReadlineAction =
  case sequence
  of "":
    action(rakEof)
  of "\r", "\n":
    action(rakSubmit)
  of "\x7f", "\x08":
    action(rakBackspace)
  of "\x0c":
    action(rakClearScreen)
  of "\x04":
    action(rakEof)
  of "\e[A":
    action(rakHistoryPrev)
  of "\e[B":
    action(rakHistoryNext)
  of "\e[C":
    action(rakMoveRight)
  of "\e[D":
    action(rakMoveLeft)
  else:
    if sequence.len == 1 and sequence[0] >= ' ':
      action(rakInsertText, sequence)
    else:
      action(rakNone)

proc decodeWindowsReadlineKey*(first: char; second = '\0'): ReadlineAction =
  case first
  of '\r', '\n':
    action(rakSubmit)
  of '\b', '\x7f':
    action(rakBackspace)
  of '\x0c':
    action(rakClearScreen)
  of '\x1a':
    action(rakEof)
  of '\x00', '\xe0':
    case second
    of 'H':
      action(rakHistoryPrev)
    of 'P':
      action(rakHistoryNext)
    of 'M':
      action(rakMoveRight)
    of 'K':
      action(rakMoveLeft)
    else:
      action(rakNone)
  else:
    if first >= ' ':
      action(rakInsertText, $first)
    else:
      action(rakNone)

proc isInteractiveStdin*(): bool =
  when defined(windows):
    let handle = getStdHandle(STD_INPUT_HANDLE)
    if handle == INVALID_HANDLE_VALUE:
      return false
    var mode: DWORD
    getConsoleMode(handle, addr mode) != 0
  else:
    stdin.getFileHandle().isatty() != 0

proc clearScreenAndHome() =
  stdout.eraseScreen()
  stdout.setCursorPos(0, 0)

proc redrawReadline(state: ReadlineState; previousWidth: var int) =
  stdout.write("\r")
  stdout.write(state.prompt)
  stdout.write(state.buffer)
  let currentWidth = state.prompt.len + state.buffer.len
  if previousWidth > currentWidth:
    stdout.write(repeat(' ', previousWidth - currentWidth))
  stdout.write("\r")
  stdout.write(state.prompt)
  if state.cursor > 0:
    stdout.write(state.buffer[0 ..< state.cursor])
  stdout.flushFile()
  previousWidth = currentWidth

proc readInteractiveUnixSequence(fd: cint): string =
  var ch: char
  let count = readBuffer(stdin, addr ch, 1)
  if count <= 0:
    return ""
  result.add(ch)
  if ch != '\e':
    return

  while true:
    let nextCount = readBuffer(stdin, addr ch, 1)
    if nextCount <= 0:
      break
    result.add(ch)
    if ch in {'A', 'B', 'C', 'D'}:
      break
    if result.len == 2 and result[1] != '[':
      break
    if result.len > 3:
      break

proc readInteractiveLine*(prompt: string; history: seq[string] = @[]): tuple[ok: bool, line: string] =
  var state = initReadlineState(prompt, history)
  var previousWidth = 0
  stdout.write(prompt)
  stdout.flushFile()

  when defined(windows):
    while true:
      let first = getch()
      let event =
        if first == '\x00' or first == '\xe0':
          decodeWindowsReadlineKey(first, getch())
        else:
          decodeWindowsReadlineKey(first)
      let effect = state.applyReadlineAction(event)
      if effect.eof:
        stdout.write("\n")
        stdout.flushFile()
        return (false, "")
      if effect.clearScreen:
        clearScreenAndHome()
      if effect.redraw:
        redrawReadline(state, previousWidth)
      if effect.submit:
        stdout.write("\n")
        stdout.flushFile()
        return (true, state.buffer)
  else:
    let fd = stdin.getFileHandle()
    var oldMode, rawMode: Termios
    var pendingResult: tuple[done: bool, ok: bool, line: string]
    discard fd.tcGetAttr(addr oldMode)
    rawMode = oldMode
    rawMode.c_iflag = rawMode.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
    rawMode.c_oflag = rawMode.c_oflag and not Cflag(OPOST)
    rawMode.c_cflag = (rawMode.c_cflag and not Cflag(CSIZE or PARENB)) or CS8
    rawMode.c_lflag = rawMode.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
    rawMode.c_cc[VMIN] = char(1)
    rawMode.c_cc[VTIME] = char(0)
    discard fd.tcSetAttr(TCSAFLUSH, addr rawMode)
    try:
      while true:
        let event = decodeUnixReadlineSequence(readInteractiveUnixSequence(fd))
        let effect = state.applyReadlineAction(event)
        if effect.eof:
          pendingResult = (true, false, "")
          break
        if effect.clearScreen:
          clearScreenAndHome()
        if effect.redraw:
          redrawReadline(state, previousWidth)
        if effect.submit:
          pendingResult = (true, true, state.buffer)
          break
    finally:
      discard fd.tcSetAttr(TCSADRAIN, addr oldMode)
    if pendingResult.done:
      stdout.writeLine("")
      stdout.flushFile()
      return (pendingResult.ok, pendingResult.line)

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
    for arg in args:
      result =  evaluator.evaluateQuoted(arg, env)
      stdout.write(render(result)))

  discard builder.command("write-line", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len == 0:
      echo ""
      return newText("")
    for arg in args:
      result = evaluator.evaluateQuoted(arg, env)
      echo render(result))

  discard builder.command("write-error", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    result = evaluator.evaluateQuoted(args[0], env)
    stderr.write(render(result)))

  discard builder.command("write-error-line", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len == 0:
      stderr.writeLine("")
      return newText("")
    for arg in args:
      result = evaluator.evaluateQuoted(arg, env)
      stderr.writeLine(render(result)))

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
      newText(stdin.readLine())
    except EOFError:
      newBoolean(false))

  discard builder.command("readline", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let prompt =
      if args.len > 0:
        requireText(evaluator.evaluateQuoted(args[0], env), "readline")
      else:
        ""
    if isInteractiveStdin():
      let line = readInteractiveLine(prompt, readlineHistory)
      if line.ok:
        newText(line.line)
      else:
        newBoolean(false)
    else:
      stdout.write(prompt)
      stdout.flushFile()
      try:
        newText(stdin.readLine())
      except EOFError:
        newBoolean(false))

  discard builder.command("readline-history-add", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let entry = requireText(evaluator.evaluateQuoted(args[0], env), "readline-history-add")
    readlineHistory.add(entry)
    newInteger(readlineHistory.len))

  discard builder.command("read-file", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let path = requireText(evaluator.evaluateQuoted(args[0], env), "read-file")
    newText(readFile(path)))

  discard builder.command("write-file", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let path = requireText(evaluator.evaluateQuoted(args[0], env), "write-file")
    let text = requireText(evaluator.evaluateQuoted(args[1], env), "write-file")
    writeFile(path, text)
    newBoolean(true))

  discard builder.command("file-info", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let kind = requireSymbol(evaluator.evaluateQuoted(args[0], env), "file-info")
    let path = requireText(evaluator.evaluateQuoted(args[1], env), "file-info")
    case kind
    of ":last-updated":
      let modified = getLastModificationTime(path)
      newInteger((modified.toUnix * 1_000_000_000'i64 + modified.nanosecond.int64).int)
    else:
      raise newException(ValueError, "'file-info' does not support kind '" & kind & "'."))

  discard builder.command("sleep", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    let seconds = requireInteger(evaluator.evaluateQuoted(args[0], env), "sleep")
    if seconds < 0:
      raise newException(ValueError, "'sleep' expects a non-negative integer.")
    sleep(seconds * 1000)
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

proc buildHttpModule*(): NativeModuleDefinition =
  var builder = initNativeModuleBuilder("http")

  discard builder.command("sse-start", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 1:
      raise newException(ValueError, "'sse-start' expects exactly one argument.")
    let path = requireText(evaluator.evaluateQuoted(args[0], env), "sse-start")
    if path.len == 0 or path[0] != '/':
      raise newException(ValueError, "'sse-start' expects a path starting with '/'.")
    let state = startSseServer(path)
    newTableValue({
      "port": newInteger(state.port.int),
      "path": newText(path),
      "url": newText("http://127.0.0.1:" & $state.port.int & path)
    }))

  discard builder.command("sse-publish", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 3:
      raise newException(ValueError, "'sse-publish' expects exactly three arguments.")
    let path = requireText(evaluator.evaluateQuoted(args[0], env), "sse-publish")
    let eventName = requireText(evaluator.evaluateQuoted(args[1], env), "sse-publish")
    let data = requireText(evaluator.evaluateQuoted(args[2], env), "sse-publish")
    newBoolean(publishSseEvent(path, eventName, data)))

  discard builder.command("sse-stop", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 1:
      raise newException(ValueError, "'sse-stop' expects exactly one argument.")
    let path = requireText(evaluator.evaluateQuoted(args[0], env), "sse-stop")
    newBoolean(stopSseServer(path)))

  builder.build()

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

  discard builder.command("serialize", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 1:
      raise newException(ValueError, "'serialize' expects exactly one argument.")
    serializeNode(evaluator.evaluateQuoted(args[0], env)))

  discard builder.command("text", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 1:
      raise newException(ValueError, "'text' expects exactly one argument.")
    let node = requireTable(evaluator.evaluateQuoted(args[0], env), "text")
    let kind = requireText(getField(node, "kind", "text"), "text")
    if kind != "symbol":
      raise newException(ValueError, "'text' expects a symbol AST node.")
    newText(requireText(getField(node, "text", "text"), "text")))

  discard builder.command("symbol", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 1:
      raise newException(ValueError, "'symbol' expects exactly one argument.")
    serializeNode(newSymbol(requireText(evaluator.evaluateQuoted(args[0], env), "symbol"))))

  discard builder.command("command", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 1:
      raise newException(ValueError, "'command' expects exactly one argument.")
    let items = requireSequence(evaluator.evaluateQuoted(args[0], env), "command")
    var objects: seq[Value]
    for item in items.items:
      objects.add(requireTable(item, "command"))
    newTableValue({
      "kind": newText("command"),
      "render": newText(""),
      "start": newInteger(0),
      "finish": newInteger(0),
      "leading-comments": newSequence(@[]),
      "trailing-comments": newSequence(@[]),
      "objects": newSequence(objects)
    }))

  discard builder.command("block", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 1:
      raise newException(ValueError, "'block' expects exactly one argument.")
    let items = requireSequence(evaluator.evaluateQuoted(args[0], env), "block")
    var commands: seq[Value]
    for item in items.items:
      commands.add(requireTable(item, "block"))
    newTableValue({
      "kind": newText("block"),
      "render": newText(""),
      "start": newInteger(0),
      "finish": newInteger(0),
      "leading-comments": newSequence(@[]),
      "trailing-comments": newSequence(@[]),
      "suffix-comments": newSequence(@[]),
      "commands": newSequence(commands)
    }))

  discard builder.command("eval-node", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len < 1 or args.len > 2:
      raise newException(ValueError, "'eval-node' expects an AST node and an optional scope argument.")
    let targetEnv =
      if args.len == 2:
        capturedEnv(args[1], evaluator, env)
      else:
        env
    evaluator.evaluate(deserializeNode(evaluator.evaluateQuoted(args[0], env)), targetEnv))

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

proc buildDocsModule*(): NativeModuleDefinition =
  var builder = initNativeModuleBuilder("docs")
  discard builder.command("generate-html", proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value =
    if args.len != 1:
      raise newException(ValueError, "'generate-html' expects exactly one output path.")
    let outputPath = requireText(evaluator.evaluateQuoted(args[0], env), "generate-html")
    writeFile(outputPath, renderDocPage(env))
    newText(outputPath))
  builder.build
