import std/[sequtils, strutils, tables]
import diagnostics
import model

type
  CommentTrivia* = object
    text*: string
    span*: SourceSpan
    hasCodeBefore*: bool

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
    postfixBinaryOperators: Table[string, bool]

  ReaderReplacementRule = object
    match: seq[string]
    replacement: seq[Token]

  ImplicitBlock = object
    indent: string
    opener: Token
    hasBody: bool

  PhysicalLine = object
    indent: string
    startPos: int
    tokenStart: int
    tokenEnd: int
    lastCodeToken: int
    hasCode: bool

const
  OperatorChars = {'!', '$', '%', '&', '*', '+', '-', '.', '/', ':', '<', '=', '>', '?', '@', '^', '~'}
  SingleCharacterSymbols = {'{', '}', '(', ')', '[', ']'}
  DotIndexMarker = ":dot-index"

proc parserError(message: string; span: SourceSpan): SushiError =
  newSushiError(message, span)

proc isIdentifierStart(ch: char): bool =
  ch.isAlphaAscii or ch == '_'

proc initParser(source: SourceFile): Parser =
  result.source = source
  result.precedences = {
    ":": 0, "??": 0, "!!": 0, "++" : 0,
    "or": 1, "and": 2, "eq": 3, "not-eq": 3, 
    "<": 4, ">": 4, "+": 5, "-": 5, "*": 6, "/": 6, 
    "%": 6, "^": 7, ".": 8
  }.toTable
  result.rightAssociative = @["^"]
  result.unaryOperators = @["not", "-"]
  result.postfixBinaryOperators = {"??": true, "!!": true}.toTable

proc tryConsumeLineContinuation(parser: Parser; index: var int): bool
proc readTextLiteralToken(parser: Parser; index: var int; startPos: int): Token

proc readerReplacementRules(): seq[ReaderReplacementRule] =
  proc symToken(value: string): Token =
    Token(kind: Symbol, lexeme: value, span: noneSpan(), textSegments: @[])
  proc termToken(): Token =
    Token(kind: Terminator, lexeme: "\n", span: noneSpan(), textSegments: @[])
  @[
    ReaderReplacementRule(match: @["#["], replacement: @[symToken("["), symToken("list")]),
    ReaderReplacementRule(match: @["{"], replacement: @[symToken("["), symToken("table")]),
    ReaderReplacementRule(match: @["}"], replacement: @[symToken("]")]),
    ReaderReplacementRule(match: @["else"], replacement: @[symToken("end"), symToken("do")]),
    ReaderReplacementRule(match: @["elif"], replacement: @[symToken("end"), termToken(), symToken("if")])
  ]

proc scanComments*(source: SourceFile): seq[CommentTrivia] =
  var parser = initParser(source)
  var index = 0
  var sawCodeOnLine = false
  let text = source.text

  while index < text.len:
    let ch = text[index]
    if ch == '\\':
      if parser.tryConsumeLineContinuation(index):
        continue
      sawCodeOnLine = true
      inc index
      continue
    if ch == '"':
      discard parser.readTextLiteralToken(index, index)
      sawCodeOnLine = true
      continue
    if ch == ';':
      let startPos = index
      while index < text.len and text[index] != '\n':
        inc index
      result.add(CommentTrivia(
        text: text[startPos ..< index],
        span: sourceSpan(source, startPos, index),
        hasCodeBefore: sawCodeOnLine
      ))
      continue
    if ch == '\n':
      sawCodeOnLine = false
      inc index
      continue
    if ch.isSpaceAscii:
      inc index
      continue
    sawCodeOnLine = true
    inc index

proc span(parser: Parser; startPos, endPos: int): SourceSpan =
  sourceSpan(parser.source, startPos, endPos)

proc addToken(parser: var Parser; kind: TokenKind; lexeme: string; startPos, endPos: int;
    textSegments: seq[TextTokenSegment] = @[]) =
  parser.tokens.add(Token(kind: kind, lexeme: lexeme, span: parser.span(startPos, endPos), textSegments: textSegments))

proc newReplacementToken(kind: TokenKind; lexeme: string; span: SourceSpan): Token =
  Token(kind: kind, lexeme: lexeme, span: span, textSegments: @[])

proc lineIndent(source: SourceFile; line: int): string =
  if line < 1 or line > source.lineStarts.len:
    return ""
  var index = source.lineStarts[line - 1]
  while index < source.len and source.text[index] in {' ', '\t'}:
    inc index
  source.text[source.lineStarts[line - 1] ..< index]

proc buildPhysicalLines(parser: Parser): seq[PhysicalLine] =
  result = newSeq[PhysicalLine](parser.source.lineStarts.len)
  for lineIndex in 0 ..< result.len:
    result[lineIndex] = PhysicalLine(
      indent: parser.source.lineIndent(lineIndex + 1),
      startPos: parser.source.lineStarts[lineIndex],
      tokenStart: -1,
      tokenEnd: -1,
      lastCodeToken: -1,
      hasCode: false
    )

  for tokenIndex, token in parser.tokens:
    let line = token.span.startLocation.line - 1
    if line < 0 or line >= result.len:
      continue
    if result[line].tokenStart < 0:
      result[line].tokenStart = tokenIndex
    result[line].tokenEnd = tokenIndex
    if token.kind != Terminator:
      result[line].hasCode = true
      result[line].lastCodeToken = tokenIndex

proc isStrictIndentedChild(childIndent, parentIndent: string): bool =
  childIndent.len > parentIndent.len and childIndent.startsWith(parentIndent)

proc applyIndentedBlockRewrites(parser: var Parser) =
  if parser.tokens.len == 0:
    return

  let source = parser.source
  let lines = parser.buildPhysicalLines()
  var rewritten: seq[Token]
  var stack: seq[ImplicitBlock]

  proc closeImplicitBlocks(span: SourceSpan) =
    while stack.len > 0:
      rewritten.add(newReplacementToken(Symbol, "end", span))
      discard stack.pop()

  proc closeImplicitBlocksBeforeLine(line: PhysicalLine): bool =
    result = false
    while stack.len > 0:
      let top = stack[^1]
      if not top.hasBody:
        if line.indent.isStrictIndentedChild(top.indent):
          stack[^1].hasBody = true
          break
        raise parserError("Implicit '\\\\' block requires an indented body.", top.opener.span)
      if line.indent.isStrictIndentedChild(top.indent):
        break
      rewritten.add(newReplacementToken(Symbol, "end", sourceSpan(source, line.startPos, line.startPos)))
      discard stack.pop()
      result = true

  for line in lines:
    if line.hasCode:
      if closeImplicitBlocksBeforeLine(line):
        rewritten.add(newReplacementToken(Terminator, "\n", sourceSpan(source, line.startPos, line.startPos)))

    if line.tokenStart < 0:
      continue

    var inlineBlockCount = 0
    for tokenIndex in line.tokenStart .. line.tokenEnd:
      let token = parser.tokens[tokenIndex]
      if token.kind == Terminator and inlineBlockCount > 0:
        let closeSpan = sourceSpan(source, token.span.start, token.span.start)
        for _ in 0 ..< inlineBlockCount:
          rewritten.add(newReplacementToken(Symbol, "end", closeSpan))
        inlineBlockCount = 0
      if token.kind == Symbol and token.lexeme == "\\\\":
        rewritten.add(newReplacementToken(Symbol, "do", token.span))
        if tokenIndex == line.lastCodeToken:
          stack.add(ImplicitBlock(indent: line.indent, opener: token, hasBody: false))
        else:
          inc inlineBlockCount
        continue
      rewritten.add(token)

    if inlineBlockCount > 0:
      let closeSpan = sourceSpan(source, parser.tokens[line.lastCodeToken].span.finish, parser.tokens[line.lastCodeToken].span.finish)
      for _ in 0 ..< inlineBlockCount:
        rewritten.add(newReplacementToken(Symbol, "end", closeSpan))

  closeImplicitBlocks(sourceSpan(source, source.len, source.len))
  parser.tokens = rewritten

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
      if index + 1 < source.len and source[index + 1] == '\\':
        parser.addToken(Symbol, "\\\\", index, index + 2)
        index += 2
        continue
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

proc applyReaderReplacements(parser: var Parser) =
  let rules = readerReplacementRules()
  if rules.len == 0 or parser.tokens.len == 0:
    return

  var rewritten: seq[Token]
  var index = 0
  while index < parser.tokens.len:
    var matchedRule = -1
    var matchedLen = 0
    for ruleIndex, rule in rules:
      if rule.match.len == 0 or index + rule.match.len > parser.tokens.len:
        continue
      var ok = true
      for offset, lexeme in rule.match:
        let token = parser.tokens[index + offset]
        if token.kind != Symbol or token.lexeme != lexeme:
          ok = false
          break
      if ok and rule.match.len > matchedLen:
        matchedRule = ruleIndex
        matchedLen = rule.match.len

    if matchedRule >= 0:
      let replacementSpan = cover(parser.tokens[index].span, parser.tokens[index + matchedLen - 1].span)
      for replacement in rules[matchedRule].replacement:
        rewritten.add(newReplacementToken(replacement.kind, replacement.lexeme, replacementSpan))
      index += matchedLen
      continue

    rewritten.add(parser.tokens[index])
    inc index

  parser.tokens = rewritten

proc isAtEnd(parser: Parser): bool = parser.tokenIndex >= parser.tokens.len

proc peek(parser: Parser): Token =
  if parser.isAtEnd:
    raise parserError("Unexpected end of input", sourceSpan(parser.source, parser.source.len, parser.source.len))
  parser.tokens[parser.tokenIndex]

proc advance(parser: var Parser): Token =
  result = parser.peek
  inc parser.tokenIndex

proc check(parser: Parser; lexeme: string): bool =
  not parser.isAtEnd and parser.tokens[parser.tokenIndex].kind == Symbol and
    parser.tokens[parser.tokenIndex].lexeme == lexeme

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
  if op in [")", "]", "}", "end"]:
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
proc readCommand(parser: var Parser): Value
proc readScript(parser: var Parser): Value
proc readPostfixExpression(parser: var Parser): Value
proc readFnValue(parser: var Parser): Value
proc readDotRight(parser: var Parser; dotSpan: SourceSpan): Value
proc readAtom(parser: var Parser): Value
proc readSimpleObject(parser: var Parser): Value
proc readObject(parser: var Parser; allowUnaryPrefix: bool): Value

proc parseTemplateObject(parser: Parser; source: string; outerSpan: SourceSpan): Value =
  var nested = initParser(newSourceFile(parser.source.name, source))
  nested.tokenize()
  nested.applyReaderReplacements()
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

proc isOperatorSuffixToken(token: Token): bool =
  if token.kind != Symbol or token.lexeme.len == 0 or token.lexeme[^1] != '=':
    return false
  token.lexeme.allIt(it in OperatorChars)

proc startsObjectLikeSymbol(lexeme: string): bool =
  lexeme in ["[", "(", "do", "fn"] or
    (lexeme.len > 0 and isIdentifierStart(lexeme[0])) or
    (lexeme.len > 1 and lexeme[0] == ':' and isIdentifierStart(lexeme[1]))

proc hasAttachedOperatorSuffix(lexeme: string): bool =
  if lexeme.len == 0 or not isIdentifierStart(lexeme[0]):
    return false
  var i = 1
  while i < lexeme.len:
    let ch = lexeme[i]
    if ch.isAlphaNumeric or ch == '_' or ch == '-':
      inc i
    else:
      return true
  false

proc canAbsorbSpacedOperatorSuffix(value: Value): bool =
  if value.isNil:
    return false
  case value.kind
  of Symbol:
    not hasAttachedOperatorSuffix(value.symbolValue)
  of Command:
    value.objects.len == 3 and value.objects[0].kind == Symbol and value.objects[0].symbolValue == "." and
      value.objects[2].kind == Symbol and not hasAttachedOperatorSuffix(value.objects[2].symbolValue)
  else:
    false

proc appendOperatorSuffix(value: Value; suffix: Token): Value =
  case value.kind
  of Symbol:
    newSymbol(value.symbolValue & suffix.lexeme, cover(value.span, suffix.span))
  of Command:
    if value.objects.len == 3 and value.objects[0].kind == Symbol and value.objects[0].symbolValue == "." and
        value.objects[2].kind == Symbol:
      var objects = value.objects
      objects[2] = newSymbol(objects[2].symbolValue & suffix.lexeme, cover(objects[2].span, suffix.span))
      newCommand(objects, cover(value.span, suffix.span))
    else:
      value
  else:
    value

proc tryConsumeSpacedOperatorSuffix(parser: var Parser; value: var Value; suffix: var Token): bool =
  if parser.isAtEnd or not value.canAbsorbSpacedOperatorSuffix:
    return false
  let token = parser.peek
  if not token.isOperatorSuffixToken:
    return false
  suffix = parser.advance
  value = value.appendOperatorSuffix(suffix)
  true

proc readAtom(parser: var Parser): Value =
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
    raise parserError("Unexpected token in object: " & token.lexeme, token.span)

proc readPrefixExpression(parser: var Parser): Value =
  let token = parser.peek
  if token.kind == Symbol and token.lexeme in parser.unaryOperators:
    let op = parser.advance
    let operand = parser.readExpression(6)
    return newCommand(@[newSymbol(op.lexeme, op.span), operand], cover(op.span, operand.span))
  parser.readAtom

proc readParenthesizedExpression(parser: var Parser): Value =
  let openTok = parser.expect("(", "Expected '(' to start expression")
  let expression = parser.readExpression(0)
  if not parser.check(")"):
    if not parser.isAtEnd:
      let nextTok = parser.peek
      raise parserError(
        "Parentheses only group expressions; use brackets for command invocation like [to-string x].",
        cover(openTok.span, nextTok.span)
      )
    raise parserError("Unbalanced parenthesis", openTok.span)
  let closeTok = parser.advance
  normalizeTuple(withSpan(expression, cover(openTok.span, expression.span, closeTok.span)))

proc readDotRight(parser: var Parser; dotSpan: SourceSpan): Value =
  if parser.check("("):
    let grouped = parser.readParenthesizedExpression()
    return newCommand(@[newSymbol(DotIndexMarker, dotSpan), grouped], cover(dotSpan, grouped.span))
  if parser.isAtEnd or parser.peek.kind != Symbol:
    raise parserError("Expected member name or '(...' after '.'.", dotSpan)
  parser.readSymbolValue

proc readBracketCommand(parser: var Parser): Value =
  let openTok = parser.expect("[", "Expected '[' to start command")
  var objects: seq[Value]
  while not parser.isAtEnd:
    while parser.checkTerminator:
      parser.consumeTerminator()
    if parser.check("]"):
      let closeTok = parser.advance
      return newCommand(objects, cover(openTok.span, coverObjects(objects), closeTok.span))
    var obj = parser.readObject(objects.len != 0)
    if objects.len == 0:
      var suffix: Token
      discard parser.tryConsumeSpacedOperatorSuffix(obj, suffix)
    if not obj.isNil:
      objects.add(obj)
  raise parserError("Expected ']' to end command", openTok.span)

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
    let right = parser.readDotRight(dot.span)
    value = newCommand(@[newSymbol(".", dot.span), value, right], cover(value.span, dot.span, right.span))
  while not parser.isAtEnd and parser.peek.kind == Symbol and parser.peek.lexeme in parser.postfixBinaryOperators:
    let op = parser.advance
    let right = parser.readSimpleObject()
    if right.isNil:
      raise parserError("Expected value after '" & op.lexeme & "'.", op.span)
    value = newCommand(@[newSymbol(op.lexeme, op.span), value, right], cover(value.span, op.span, right.span))
  value

proc readSimpleObject(parser: var Parser): Value =
  let token = parser.peek
  case token.kind
  of Terminator:
    nil
  else:
    parser.readAtom()

proc readExpression(parser: var Parser; minPrecedence: int): Value =
  var left = parser.readPrefixExpression()
  while not parser.isAtEnd:
    if parser.checkTerminator or parser.check(")"):
      break
    var suffix: Token
    if parser.tryConsumeSpacedOperatorSuffix(left, suffix):
      let right = parser.readSimpleObject()
      if right.isNil:
        raise parserError("Expected value after '" & suffix.lexeme & "'.", suffix.span)
      left = newCommand(@[left, right], cover(left.span, right.span))
      continue
    if parser.peek.kind != Symbol:
      break
    let op = parser.peek.lexeme
    if not parser.precedences.hasKey(op) and not parser.postfixBinaryOperators.hasKey(op) and
        op != ":" and startsObjectLikeSymbol(op):
      break
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

proc readObject(parser: var Parser; allowUnaryPrefix: bool): Value =
  if parser.isAtEnd:
    raise parserError("Unexpected end of input", parser.currentSpan)
  var obj: Value
  if allowUnaryPrefix and parser.peek.kind == Symbol and parser.peek.lexeme in parser.unaryOperators:
    obj = parser.readPrefixExpression()
  else:
    obj = parser.readSimpleObject()
  if obj.isNil:
    return nil
  while not parser.isAtEnd and parser.check(":"):
    let op = parser.advance
    let nextValue = parser.readSimpleObject()
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
    var obj = parser.readObject(objects.len != 0)
    if objects.len == 0:
      var suffix: Token
      discard parser.tryConsumeSpacedOperatorSuffix(obj, suffix)
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
  parser.applyIndentedBlockRewrites()
  parser.applyReaderReplacements()
  parser.readScript()

proc parseScript*(source, sourceName: string): Value =
  parseScript(newSourceFile(sourceName, source))
