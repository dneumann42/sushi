import std/[algorithm, strutils]

type
  SourceFile* = ref object
    name*, text*: string
    lineStarts*: seq[int]

  SourceLocation* = object
    file*: SourceFile
    offset*, line*, column*: int

  SourceSpan* = object
    file*: SourceFile
    start*, finish*: int

  SushiError* = ref object of CatchableError
    span*: SourceSpan

proc newSourceFile*(name, text: string): SourceFile =
  new(result)
  result.name = if name.strip.len == 0: "<input>" else: name
  result.text = text
  result.lineStarts = @[0]
  for i, ch in text:
    if ch == '\n':
      result.lineStarts.add(i + 1)

proc len*(source: SourceFile): int =
  source.text.len

proc isEmpty*(span: SourceSpan): bool =
  span.file.isNil

proc noneSpan*(): SourceSpan =
  SourceSpan()

proc sourceSpan*(file: SourceFile; startPos, endPos: int): SourceSpan =
  if file.isNil:
    return noneSpan()
  let boundedStart = clamp(startPos, 0, file.text.len)
  let boundedEnd = clamp(endPos, boundedStart, file.text.len)
  SourceSpan(file: file, start: boundedStart, finish: boundedEnd)

proc getLocation*(file: SourceFile; offset: int): SourceLocation =
  let clamped = clamp(offset, 0, file.text.len)
  var lineIndex = upperBound(file.lineStarts, clamped) - 1
  if lineIndex < 0:
    lineIndex = 0
  let lineStart = file.lineStarts[lineIndex]
  SourceLocation(
    file: file,
    offset: clamped,
    line: lineIndex + 1,
    column: (clamped - lineStart) + 1
  )

proc startLocation*(span: SourceSpan): SourceLocation =
  if span.file.isNil:
    SourceLocation()
  else:
    span.file.getLocation(span.start)

proc endLocation*(span: SourceSpan): SourceLocation =
  if span.file.isNil:
    SourceLocation()
  else:
    span.file.getLocation(max(span.start, span.finish))

proc getLineText*(file: SourceFile; line: int): string =
  if line < 1 or line > file.lineStarts.len:
    return ""
  let startPos = file.lineStarts[line - 1]
  var endPos = if line == file.lineStarts.len: file.text.len else: file.lineStarts[line] - 1
  if endPos > startPos and file.text[endPos - 1] == '\r':
    dec endPos
  file.text[startPos ..< max(startPos, endPos)]

proc cover*(spans: varargs[SourceSpan]): SourceSpan =
  var file: SourceFile
  var startPos = high(int)
  var endPos = low(int)
  for span in spans:
    if span.isEmpty:
      continue
    if file.isNil:
      file = span.file
    if span.file != file:
      continue
    startPos = min(startPos, span.start)
    endPos = max(endPos, span.finish)
  if file.isNil:
    noneSpan()
  else:
    sourceSpan(file, startPos, endPos)

proc newSushiError*(message: string; span = noneSpan()): SushiError =
  new(result)
  result.msg = message
  result.span = span

proc wrapSushiError*(err: ref CatchableError; span = noneSpan()): SushiError =
  if err of SushiError:
    let existing = SushiError(err)
    if existing.span.isEmpty and not span.isEmpty:
      return newSushiError(existing.msg, span)
    return existing
  newSushiError(err.msg, span)

proc formatDiagnostic*(err: ref CatchableError; useColor = true): string =
  let diagnostic = wrapSushiError(err)
  let red = if useColor: "\e[31m" else: ""
  let reset = if useColor: "\e[0m" else: ""

  result = red & "error" & reset & ": " & diagnostic.msg
  if diagnostic.span.isEmpty:
    return

  let span = diagnostic.span
  let startLoc = span.startLocation
  let endLoc = span.endLocation
  let underlineStart = max(startLoc.column - 1, 0)
  let underlineLength =
    max(1, (if startLoc.line == endLoc.line: endLoc.column else: startLoc.column + 1) - startLoc.column)
  let firstLine = max(1, startLoc.line - 1)
  let lastLine = startLoc.line
  let width = ($startLoc.line).len

  result.add "\n --> " & startLoc.file.name & ":" & $startLoc.line & ":" & $startLoc.column
  result.add "\n  |"
  for line in firstLine .. lastLine:
    result.add "\n" & align($line, width) & " | " & startLoc.file.getLineText(line)
    if line == startLoc.line:
      result.add "\n" & repeat(' ', width) & " | "
      result.add repeat(' ', underlineStart)
      result.add red & repeat('^', underlineLength) & reset
