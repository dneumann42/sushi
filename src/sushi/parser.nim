import std/[sequtils, strutils, tables]
import diagnostics
import model

type
  TokenKind = enum
    Symbol,
    Number,
    Boolean,
    Text,
    Terminator

  TextTokenSegmentKind = enum
    Text,
    Template

  TextTokenSegment = object
    case kind: TextTokenSegmentKind
    of Text:
      text: string
    of Template:
      source: string

  Token = object
    kind: TokenKind
    lexeme: string
    span: SourceSpan
    textSegments: seq[TextTokenSegment]

  Parser = object
    source: SourceFile
    tokens: seq[Token]
    tokenIndex: int
    precedences: Table[string, int]
    rightAssociative: seq[string]
    unaryOperators: seq[string]

const
  OperatorChars = {'!', '$', '%', '&', '*', '+', '-', '.', '/', ':', '<', '=', '>', '?', '@', '^', '~'}
  SingleCharacterSymbols = {'{', '}', '(', ')', '[', ']'}

proc parserError(message: string; span: SourceSpan): SushiError =
  newSushiError(message, span)

proc isIdentifierStart(ch: char): bool =
  ch.isAlphaAscii or ch == '_'

proc isMemberName(lexeme: string): bool =
  if lexeme.len == 0 or not isIdentifierStart(lexeme[0]):
    return false
  var i = 1
  while i < lexeme.len:
    let ch = lexeme[i]
    if ch.isAlphaNumeric or ch == '_' or ch == '-':
      inc i
      continue
    if ch == '=' and i == lexeme.high:
      return true
    if ch in OperatorChars:
      while i < lexeme.high and lexeme[i] in OperatorChars and lexeme[i] != '=':
        inc i
      return i == lexeme.high and lexeme[i] == '='
    return false
  true

proc initParser(source: SourceFile): Parser =
  result.source = source
  result.precedences = {
    ":": 0,
    "or": 1,
    "and": 2,
    "eq": 3,
    "not-eq": 3,
    "<": 4,
    ">": 4,
    "+": 5,
    "-": 5,
    "*": 6,
    "/": 6,
    "%": 6,
    "^": 7
  }.toTable
  result.rightAssociative = @["^"]
  result.unaryOperators = @["not", "-"]

proc span(parser: Parser; startPos, endPos: int): SourceSpan =
  sourceSpan(parser.source, startPos, endPos)

proc addToken(parser: var Parser; kind: TokenKind; lexeme: string; startPos, endPos: int;
    textSegments: seq[TextTokenSegment] = @[]) =
  parser.tokens.add(Token(kind: kind, lexeme: lexeme, span: parser.span(startPos, endPos), textSegments: textSegments))

proc skipNestedString(parser: Parser; index: var int) =
  while index < parser.source.len:
    let ch = parser.source.text[index]
    inc index
    if ch == '\\':
      if index < parser.source.len:
        inc index
    elif ch == '"':
      return

proc readTemplateLiteral(parser: Parser; index: var int; stringStart: int): string =
  let startPos = index
  var depth = 1
  while index < parser.source.len:
    let ch = parser.source.text[index]
    inc index
    case ch
    of '"':
      parser.skipNestedString(index)
    of '(':
      inc depth
    of ')':
      dec depth
      if depth == 0:
        return parser.source.text[startPos ..< index - 1]
    else:
      discard
  raise parserError("Unterminated string template.", parser.span(stringStart, parser.source.len))

proc readTextLiteralToken(parser: Parser; index: var int; startPos: int): Token =
  inc index
  var buffer = ""
  var segments: seq[TextTokenSegment]

  while index < parser.source.len:
    let ch = parser.source.text[index]
    inc index
    if ch == '"':
      if buffer.len > 0:
        segments.add(TextTokenSegment(kind: Text, text: buffer))
      var lexeme = ""
      for segment in segments:
        if segment.kind == Text:
          lexeme.add(segment.text)
      return Token(kind: Text, lexeme: lexeme, span: parser.span(startPos, index), textSegments: segments)
    if ch == '\\':
      if index >= parser.source.len:
        raise parserError("Unterminated escape sequence in string literal.", parser.span(index - 1, index))
      let escaped = parser.source.text[index]
      inc index
      if escaped == '(':
        if buffer.len > 0:
          segments.add(TextTokenSegment(kind: Text, text: buffer))
          buffer.setLen(0)
        segments.add(TextTokenSegment(kind: Template, source: parser.readTemplateLiteral(index, startPos)))
        continue
      buffer.add(case escaped
        of 'n': '\n'
        of 'r': '\r'
        of 't': '\t'
        of '\\': '\\'
        of '"': '"'
        else: escaped)
      continue
    buffer.add(ch)
  raise parserError("Unterminated string literal.", parser.span(startPos, parser.source.len))

proc readNumber(source: string; index: var int): string =
  let startPos = index
  var sawDecimal = false
  while index < source.len:
    let ch = source[index]
    if ch.isDigit:
      inc index
    elif ch == '.' and not sawDecimal:
      sawDecimal = true
      inc index
    else:
      break
  source[startPos ..< index]

proc readIdentifier(source: string; index: var int): string =
  let startPos = index
  inc index
  while index < source.len:
    let ch = source[index]
    if ch.isAlphaNumeric or ch == '_' or ch == '-':
      inc index
    else:
      break
  let opStart = index
  while index < source.len and source[index] in OperatorChars and source[index] != '=':
    inc index
  if index < source.len and source[index] == '=' and (index + 1 >= source.len or source[index + 1] notin OperatorChars):
    inc index
  else:
    index = opStart
  source[startPos ..< index]

proc readOperator(source: string; index: var int): string =
  let startPos = index
  while index < source.len and source[index] in OperatorChars:
    inc index
  source[startPos ..< index]

proc readKeywordSymbol(source: string; index: var int): string =
  let startPos = index
  index += 2
  while index < source.len:
    let ch = source[index]
    if ch.isAlphaNumeric or ch == '_' or ch == '-':
      inc index
    else:
      break
  source[startPos ..< index]

proc tryConsumeLineContinuation(parser: Parser; index: var int): bool =
  var lookahead = index + 1
  while lookahead < parser.source.len and parser.source.text[lookahead] in {' ', '\t'}:
    inc lookahead
  if lookahead < parser.source.len and parser.source.text[lookahead] == ';':
    while lookahead < parser.source.len and parser.source.text[lookahead] != '\n':
      inc lookahead
  if lookahead < parser.source.len and parser.source.text[lookahead] == '\n':
    index = lookahead + 1
    return true
  false

proc tokenize(parser: var Parser) =
  parser.tokens.setLen(0)
  var index = 0
  let source = parser.source.text

  while index < source.len:
    let ch = source[index]
    if ch == '\\':
      if parser.tryConsumeLineContinuation(index):
        continue
      raise parserError("Unsupported character '\\'.", parser.span(index, index + 1))
    if ch.isSpaceAscii and ch != '\n':
      inc index
      continue
    if ch == '\n' or ch == ';':
      if ch == '\n':
        parser.addToken(Terminator, $ch, index, index + 1)
        inc index
      else:
        while index < source.len and source[index] != '\n':
          inc index
      continue
    if ch == '#' and index + 1 < source.len and source[index + 1] == '[':
      parser.addToken(Symbol, "#[", index, index + 2)
      index += 2
      continue
    if ch == ':' and index + 1 < source.len and isIdentifierStart(source[index + 1]):
      let startPos = index
      let lexeme = readKeywordSymbol(source, index)
      parser.addToken(Symbol, lexeme, startPos, index)
      continue
    if ch == '"':
      let startPos = index
      parser.tokens.add(parser.readTextLiteralToken(index, startPos))
      continue
    if ch.isDigit:
      let startPos = index
      let lexeme = readNumber(source, index)
      parser.addToken(Number, lexeme, startPos, index)
      continue
    if isIdentifierStart(ch):
      let startPos = index
      let lexeme = readIdentifier(source, index)
      parser.addToken(if lexeme in ["T", "F"]: TokenKind.Boolean else: TokenKind.Symbol, lexeme, startPos, index)
      continue
    if ch in SingleCharacterSymbols:
      parser.addToken(Symbol, $ch, index, index + 1)
      inc index
      continue
    if ch == '.':
      parser.addToken(Symbol, ".", index, index + 1)
      inc index
      continue
    if ch in OperatorChars:
      let startPos = index
      let lexeme = readOperator(source, index)
      parser.addToken(Symbol, lexeme, startPos, index)
      continue
    raise parserError("Unsupported character '" & $ch & "'.", parser.span(index, index + 1))

proc isAtEnd(parser: Parser): bool = parser.tokenIndex >= parser.tokens.len

proc peek(parser: Parser): Token =
  if parser.isAtEnd:
    raise parserError("Unexpected end of input", sourceSpan(parser.source, parser.source.len, parser.source.len))
  parser.tokens[parser.tokenIndex]

proc advance(parser: var Parser): Token =
  result = parser.peek
  inc parser.tokenIndex

proc check(parser: Parser; lexeme: string): bool =
  not parser.isAtEnd and parser.tokens[parser.tokenIndex].lexeme == lexeme

proc checkTerminator(parser: Parser): bool =
  not parser.isAtEnd and parser.tokens[parser.tokenIndex].kind == Terminator

proc consumeTerminator(parser: var Parser) =
  if not parser.checkTerminator:
    raise parserError("Expected terminator", parser.peek.span)
  inc parser.tokenIndex

proc currentSpan(parser: Parser): SourceSpan =
  if not parser.isAtEnd:
    parser.tokens[parser.tokenIndex].span
  else:
    sourceSpan(parser.source, parser.source.len, parser.source.len)

proc expect(parser: var Parser; lexeme, message: string; fallback = noneSpan()): Token =
  if not parser.check(lexeme):
    raise parserError(message, if fallback.isEmpty: parser.currentSpan else: fallback)
  parser.advance

proc coverObjects(objects: seq[Value]): SourceSpan =
  if objects.len == 0: noneSpan() else: cover(objects[0].span, objects[^1].span)

proc coverCommands(commands: seq[Value]): SourceSpan =
  if commands.len == 0: noneSpan() else: cover(commands[0].span, commands[^1].span)

proc withSpan(value: Value; span: SourceSpan): Value =
  value.span = span
  value

proc tryGetInfixPrecedence(parser: Parser; op: string; precedence: var int): bool =
  if parser.precedences.hasKey(op):
    precedence = parser.precedences[op]
    return true
  if op in [".", ")", "]", "}", "end"]:
    precedence = 0
    return false
  precedence = 0
  true

proc createTupleNode(left, right: Value; operatorSpan: SourceSpan): Value =
  newCommand(@[newSymbol(":", operatorSpan), left, right], cover(left.span, operatorSpan, right.span))

proc collectTupleItems(value: Value; items: var seq[Value])

proc tryCollectTupleItems(value: Value; items: var seq[Value]): bool =
  if value.kind == Command and value.objects.len == 3 and value.objects[0].kind == Symbol and value.objects[0].symbolValue == ":":
    items = @[]
    collectTupleItems(value.objects[1], items)
    collectTupleItems(value.objects[2], items)
    return true
  false

proc collectTupleItems(value: Value; items: var seq[Value]) =
  if value.kind == Command and value.objects.len == 3 and value.objects[0].kind == Symbol and value.objects[0].symbolValue == ":":
    collectTupleItems(value.objects[1], items)
    collectTupleItems(value.objects[2], items)
  else:
    items.add(value)

proc normalizeTuple(value: Value): Value =
  var items: seq[Value]
  if tryCollectTupleItems(value, items):
    result = newSequence(items, value.span)
  else:
    result = value

proc readExpression(parser: var Parser; minPrecedence: int): Value
proc readObject(parser: var Parser): Value
proc readCommand(parser: var Parser): Value
proc readScript(parser: var Parser): Value
proc readPostfixExpression(parser: var Parser): Value
proc readCommandObject(parser: var Parser; isHead: bool): Value
proc readFnValue(parser: var Parser): Value

proc parseTemplateObject(parser: Parser; source: string; outerSpan: SourceSpan): Value =
  var nested = initParser(newSourceFile(parser.source.name, source))
  nested.tokenize()
  let script = nested.readScript()
  if script.commands.len != 1:
    raise parserError("String template expects exactly one object.", outerSpan)
  let command = script.commands[0]
  if command.objects.len == 0:
    raise parserError("String template cannot be empty.", outerSpan)
  if command.objects.len == 1:
    return withSpan(command.objects[0], outerSpan)
  withSpan(command, outerSpan)

proc readNumberValue(parser: var Parser): Value =
  let token = parser.advance
  if '.' in token.lexeme:
    newReal(parseFloat(token.lexeme), token.span)
  else:
    newInteger(parseInt(token.lexeme), token.span)

proc readBooleanValue(parser: var Parser): Value =
  let token = parser.advance
  newBoolean(token.lexeme == "T", token.span)

proc readTextValue(parser: var Parser): Value =
  let token = parser.advance
  if token.textSegments.len == 0 or token.textSegments.allIt(it.kind == Text):
    return newText(token.lexeme, token.span)
  var segments: seq[StringTemplateSegment]
  for segment in token.textSegments:
    case segment.kind
    of Text:
      if segment.text.len > 0:
        segments.add(StringTemplateSegment(kind: Text, text: segment.text))
    of Template:
      segments.add(StringTemplateSegment(kind: Object, obj: parser.parseTemplateObject(segment.source, token.span)))
  newStringTemplate(segments, token.span)

proc readSymbolValue(parser: var Parser): Value =
  let token = parser.advance
  newSymbol(token.lexeme, token.span)

proc readPrimaryExpression(parser: var Parser): Value =
  let token = parser.peek
  case token.kind
  of Number:
    parser.readNumberValue
  of Boolean:
    parser.readBooleanValue
  of Text:
    parser.readTextValue
  of Symbol:
    parser.readPostfixExpression
  else:
    raise parserError("Unexpected token in expression: " & token.lexeme, token.span)

proc readPrefixExpression(parser: var Parser): Value =
  let token = parser.peek
  if token.kind == Symbol and token.lexeme in parser.unaryOperators:
    let op = parser.advance
    let operand = parser.readExpression(6)
    return newCommand(@[newSymbol(op.lexeme, op.span), operand], cover(op.span, operand.span))
  parser.readPrimaryExpression

proc readIndexedArgument(parser: var Parser; openSpan: SourceSpan): Value =
  let saved = parser.tokenIndex
  let expression = parser.readExpression(0)
  if parser.check(")"):
    return expression
  parser.tokenIndex = saved
  let command = parser.readCommand()
  if command.objects.len == 0:
    raise parserError("Expected value inside indexed access.", openSpan)
  if command.objects.len == 1: command.objects[0] else: command

proc readParenthesizedExpression(parser: var Parser): Value =
  let openTok = parser.expect("(", "Expected '(' to start expression")
  let expression = parser.readExpression(0)
  let closeTok = parser.expect(")", "Unbalanced parenthesis", openTok.span)
  normalizeTuple(withSpan(expression, cover(openTok.span, expression.span, closeTok.span)))

proc readBracketCommand(parser: var Parser): Value =
  let openTok = parser.expect("[", "Expected '[' to start command")
  var objects: seq[Value]
  while not parser.isAtEnd:
    while parser.checkTerminator:
      parser.consumeTerminator()
    if parser.check("]"):
      let closeTok = parser.advance
      return newCommand(objects, cover(openTok.span, coverObjects(objects), closeTok.span))
    let obj = parser.readCommandObject(objects.len == 0)
    if not obj.isNil:
      objects.add(obj)
  raise parserError("Expected ']' to end command", openTok.span)

proc readSequenceValue(parser: var Parser): Value =
  let openTok = parser.expect("#[", "Expected '#[' to start list literal")
  var objects: seq[Value]
  while not parser.isAtEnd:
    while parser.checkTerminator and parser.peek.lexeme == "\n":
      parser.consumeTerminator()
    if parser.check("]"):
      let closeTok = parser.advance
      return newSequence(objects, cover(openTok.span, coverObjects(objects), closeTok.span))
    let item = parser.readObject()
    if item.isNil:
      raise parserError("Expected list element.", openTok.span)
    objects.add(item)
  raise parserError("Expected ']' to end list literal", openTok.span)

proc readTableValue(parser: var Parser): Value =
  let openTok = parser.expect("{", "Expected '{' to start table")
  var entries = initTable[Value, Value]()
  var spans = @[openTok.span]
  while not parser.isAtEnd and not parser.check("}"):
    while parser.checkTerminator:
      parser.consumeTerminator()
    if parser.check("}"):
      break
    let key = parser.readObject()
    if key.isNil:
      raise parserError("Expected key in table", openTok.span)
    let value = parser.readObject()
    if value.isNil:
      raise parserError("Expected value in table", key.span)
    entries[key] = value
    spans.add(key.span)
    spans.add(value.span)
    while parser.checkTerminator:
      parser.consumeTerminator()
  let closeTok = parser.expect("}", "Expected '}' to end table", openTok.span)
  spans.add(closeTok.span)
  newTable(entries, cover(spans))

proc readBlockValue(parser: var Parser): Value =
  let openTok = parser.expect("do", "Expected 'do' to start block")
  var commands: seq[Value]
  while not parser.isAtEnd:
    while parser.checkTerminator:
      parser.consumeTerminator()
    if parser.check("end"):
      let closeTok = parser.advance
      return newBlock(commands, cover(openTok.span, coverCommands(commands), closeTok.span))
    let command = parser.readCommand()
    if command.objects.len > 0:
      commands.add(command)
  raise parserError("Expected 'end' to end block", openTok.span)

proc readFnValue(parser: var Parser): Value =
  let fnTok = parser.expect("fn", "Expected 'fn' to start lambda")
  if not parser.check("["):
    raise parserError("Lambda expects a parameter list like 'fn [x] ...'.", fnTok.span)
  let parameters = parser.readBracketCommand()
  if parser.isAtEnd or parser.checkTerminator or parser.check("end") or parser.check("]") or
      parser.check("}") or parser.check(")"):
    raise parserError("Lambda requires a body after the parameter list.", parameters.span)
  let body =
    if parser.check("do"):
      parser.readBlockValue()
    else:
      let command = parser.readCommand()
      if command.objects.len == 0:
        raise parserError("Lambda requires a non-empty body.", parameters.span)
      command
  newCommand(@[newSymbol("fn", fnTok.span), parameters, body], cover(fnTok.span, parameters.span, body.span))

proc readSymbolDrivenObject(parser: var Parser): Value =
  case parser.peek.lexeme
  of "fn":
    parser.readFnValue
  of "[":
    parser.readBracketCommand
  of "#[":
    parser.readSequenceValue
  of "{":
    parser.readTableValue
  of "do":
    parser.readBlockValue
  of "(":
    parser.readParenthesizedExpression
  else:
    parser.readSymbolValue

proc readPostfixExpression(parser: var Parser): Value =
  var value = parser.readSymbolDrivenObject()
  while not parser.isAtEnd and parser.check("."):
    let dot = parser.advance
    if parser.check("("):
      let openTok = parser.advance
      let idx = parser.readIndexedArgument(openTok.span)
      let closeTok = parser.expect(")", "Unbalanced parenthesis", openTok.span)
      value = newIndexedAccess(value, normalizeTuple(idx), cover(value.span, dot.span, closeTok.span))
      continue
    if parser.isAtEnd or parser.peek.kind != Symbol or not isMemberName(parser.peek.lexeme):
      raise parserError("Expected member name or '(...)' after '.'.", dot.span)
    let member = parser.advance
    value = newMemberAccess(value, member.lexeme, cover(value.span, dot.span, member.span))
  value

proc readNonTupleObject(parser: var Parser): Value =
  let token = parser.peek
  case token.kind
  of Number:
    parser.readNumberValue
  of Boolean:
    parser.readBooleanValue
  of Text:
    parser.readTextValue
  of Terminator:
    nil
  of Symbol:
    parser.readPostfixExpression

proc readExpression(parser: var Parser; minPrecedence: int): Value =
  var left = parser.readPrefixExpression()
  while not parser.isAtEnd:
    if parser.checkTerminator or parser.check(")"):
      break
    if parser.peek.kind != Symbol:
      break
    let op = parser.peek.lexeme
    var precedence: int
    if not parser.tryGetInfixPrecedence(op, precedence):
      break
    if precedence < minPrecedence:
      break
    let operatorToken = parser.advance
    let nextMinPrecedence = if op in parser.rightAssociative: precedence else: precedence + 1
    let right = parser.readExpression(nextMinPrecedence)
    left =
      if op == ":":
        createTupleNode(left, right, operatorToken.span)
      else:
        newCommand(@[newSymbol(op, operatorToken.span), left, right], cover(left.span, operatorToken.span, right.span))
  left

proc readCommandObject(parser: var Parser; isHead: bool): Value =
  if isHead:
    return parser.readObject()
  if parser.peek.kind == Symbol and parser.peek.lexeme in parser.unaryOperators:
    var obj = parser.readPrefixExpression()
    while not parser.isAtEnd and parser.check(":"):
      let op = parser.advance
      let nextValue = parser.readNonTupleObject()
      if nextValue.isNil:
        raise parserError("Expected value after ':'.", op.span)
      obj = createTupleNode(obj, nextValue, op.span)
    return normalizeTuple(obj)
  parser.readObject()

proc readObject(parser: var Parser): Value =
  if parser.isAtEnd:
    raise parserError("Unexpected end of input", parser.currentSpan)
  var obj = parser.readNonTupleObject()
  if obj.isNil:
    return nil
  while not parser.isAtEnd and parser.check(":"):
    let op = parser.advance
    let nextValue = parser.readNonTupleObject()
    if nextValue.isNil:
      raise parserError("Expected value after ':'.", op.span)
    obj = createTupleNode(obj, nextValue, op.span)
  normalizeTuple(obj)

proc readCommand(parser: var Parser): Value =
  var objects: seq[Value]
  while not parser.isAtEnd:
    if parser.checkTerminator:
      parser.consumeTerminator()
      break
    let lexeme = parser.peek.lexeme
    if lexeme in ["end", "]", "}", ")"]:
      break
    let obj = parser.readCommandObject(objects.len == 0)
    if not obj.isNil:
      objects.add(obj)
  newCommand(objects, coverObjects(objects))

proc readScript(parser: var Parser): Value =
  var commands: seq[Value]
  parser.tokenIndex = 0
  while not parser.isAtEnd:
    while parser.checkTerminator:
      parser.consumeTerminator()
    if parser.isAtEnd:
      break
    let command = parser.readCommand()
    if command.objects.len > 0:
      commands.add(command)
    elif not parser.isAtEnd and not parser.checkTerminator:
      raise parserError("Unable to parse token: " & parser.peek.lexeme, parser.peek.span)
  newScript(commands, coverCommands(commands))

proc parseScript*(source: SourceFile): Value =
  var parser = initParser(source)
  parser.tokenize()
  parser.readScript()

proc parseScript*(source, sourceName: string): Value =
  parseScript(newSourceFile(sourceName, source))
