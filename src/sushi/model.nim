import std/[hashes, tables]
import diagnostics

type
  ValueKind* = enum
    Nil
    Symbol
    Text
    StringTemplate
    Integer
    Real
    Boolean
    Sequence
    Table
    Command
    Script
    Block
    MemberAccess
    IndexedAccess
    Array
    Module
    Class
    Instance
    CapturedSyntax
    NativeCommand
    UserCommand
    Method

  Value* = ref ValueObj

  ValueObj* = object
    span*: SourceSpan
    case kind*: ValueKind
    of Nil:
      discard
    of Symbol:
      symbolValue*: string
    of Text:
      textValue*: string
    of StringTemplate:
      templateSegments*: seq[StringTemplateSegment]
    of Integer:
      intValue*: int
    of Real:
      realValue*: float
    of Boolean:
      boolValue*: bool
    of Sequence:
      items*: seq[Value]
    of Table:
      entries*: Table[Value, Value]
    of Command:
      objects*: seq[Value]
    of Script:
      commands*: seq[Value]
    of Block:
      blockCommands*: seq[Value]
    of MemberAccess:
      receiver*: Value
      memberName*: string
    of IndexedAccess:
      indexedReceiver*: Value
      indexValue*: Value
    of Array:
      elements*: seq[Value]
      arity*: int
    of Module:
      moduleName*: string
      filePath*: string
      exports*: OrderedTable[string, Value]
      lastResult*: Value
    of Class:
      classDef*: ClassDef
    of Instance:
      instanceDef*: instanceKind
    of CapturedSyntax:
      capturedValue*: Value
      capturedEnv*: Env
    of NativeCommand:
      nativeCommand*: nativeCommandKind
    of UserCommand:
      userCommand*: userCommandKind
    of Method:
      methodDef*: MethodDef

  StringTemplateSegmentKind* = enum
    Text,
    Object

  StringTemplateSegment* = object
    kind*: StringTemplateSegmentKind
    text*: string
    obj*: Value

  NativeCommandProc* = proc (evaluator: Evaluator; env: Env; args: seq[Value]): Value

  nativeCommandKind* = ref object
    name*: string
    implementation*: NativeCommandProc
    span*: SourceSpan

  userCommandKind* = ref object
    name*: string
    parameters*: seq[Value]
    body*: Value
    definingEnv*: Env
    variadic*: bool
    span*: SourceSpan

  MethodDef* = ref object
    name*: string
    parameters*: seq[Value]
    body*: Value
    definingEnv*: Env
    declaringClass*: ClassDef
    isClassMethod*: bool
    variadic*: bool
    span*: SourceSpan

  ClassDef* = ref object
    name*: string
    baseClass*: ClassDef
    definingEnv*: Env
    runtimeState*: RuntimeState
    declaredFields*: seq[string]
    fieldDefaults*: OrderedTable[string, Value]
    instanceMethods*: OrderedTable[string, MethodDef]
    classMethods*: OrderedTable[string, MethodDef]
    span*: SourceSpan

  instanceKind* = ref object
    `class`*: ClassDef
    fields*: OrderedTable[string, Value]
    span*: SourceSpan

  RuntimeState* = ref object
    classes*: OrderedTable[string, ClassDef]
    modulesByPath*: OrderedTable[string, Value]
    nativeModulesByName*: OrderedTable[string, Value]
    loadingModules*: seq[string]
    rootEnv*: Env

  Env* = ref object
    parent*, fallback*: Env
    bindings*: OrderedTable[string, Value]
    runtimeState*: RuntimeState
    currentModule*: Value
    exportsToModule*: bool

  Evaluator* = ref object

  NativeModuleDefinition* = object
    name*: string
    exports*: OrderedTable[string, Value]

  NativeModuleBuilder* = object
    name*: string
    exports*: OrderedTable[string, Value]

proc newNilValue*(span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Nil, span: span)

proc newSymbol*(value: string; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Symbol, span: span, symbolValue: value)

proc newText*(value: string; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Text, span: span, textValue: value)

proc newInteger*(value: int; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Integer, span: span, intValue: value)

proc newReal*(value: float; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Real, span: span, realValue: value)

proc newBoolean*(value: bool; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Boolean, span: span, boolValue: value)

proc newSequence*(items: seq[Value]; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Sequence, span: span, items: items)

proc newTable*(entries: Table[Value, Value]; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Table, span: span, entries: entries)

proc newCommand*(objects: seq[Value]; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Command, span: span, objects: objects)

proc newScript*(commands: seq[Value]; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Script, span: span, commands: commands)

proc newBlock*(commands: seq[Value]; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Block, span: span, blockCommands: commands)
proc newMemberAccess*(receiver: Value; memberName: string; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: MemberAccess, span: span, receiver: receiver, memberName: memberName)
proc newIndexedAccess*(receiver, indexValue: Value; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: IndexedAccess, span: span, indexedReceiver: receiver, indexValue: indexValue)
proc newArray*(elements: seq[Value]; arity: int; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Array, span: span, elements: elements, arity: arity)
proc newCapturedSyntax*(value: Value; env: Env): Value =
  new(result)
  result[] = ValueObj(kind: CapturedSyntax, span: value.span, capturedValue: value, capturedEnv: env)
proc newNativeCommandValue*(command: nativeCommandKind): Value =
  new(result)
  result[] = ValueObj(kind: NativeCommand, span: command.span, nativeCommand: command)
proc newUserCommandValue*(command: userCommandKind): Value =
  new(result)
  result[] = ValueObj(kind: UserCommand, span: command.span, userCommand: command)
proc newMethodValue*(mdef: MethodDef): Value =
  new(result)
  result[] = ValueObj(kind: Method, span: mdef.span, methodDef: mdef)
proc newClassValue*(classDef: ClassDef; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Class, span: span, classDef: classDef)
proc newInstanceValue*(instance: instanceKind; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Instance, span: span, instanceDef: instance)
proc newModuleValue*(name, filePath: string; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: Module, span: span, moduleName: name, filePath: filePath,
    exports: initOrderedTable[string, Value](), lastResult: newNilValue())
proc newStringTemplate*(segments: seq[StringTemplateSegment]; span = noneSpan()): Value =
  new(result)
  result[] = ValueObj(kind: StringTemplate, span: span, templateSegments: segments)

proc `==`*(a, b: Value): bool

proc hash*(value: Value): Hash

proc `==`(a, b: StringTemplateSegment): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of Text:
    a.text == b.text
  of Object:
    a.obj == b.obj

proc hash(segment: StringTemplateSegment): Hash =
  result = hash(ord(segment.kind))
  case segment.kind
  of Text:
    result = result !& hash(segment.text)
  of Object:
    result = result !& hash(segment.obj)
  result = !$result

proc isCallable*(value: Value): bool =
  value.kind in {NativeCommand, UserCommand, Method}

proc keyName*(value: Value): string =
  if value.kind != Symbol:
    raise newException(ValueError, "binding name must be a symbol")
  value.symbolValue

proc initRuntimeState*(): RuntimeState =
  RuntimeState(
    classes: initOrderedTable[string, ClassDef](),
    modulesByPath: initOrderedTable[string, Value](),
    nativeModulesByName: initOrderedTable[string, Value](),
    loadingModules: @[]
  )

proc initEnv*(parent, fallback: Env; runtimeState: RuntimeState; currentModule: Value; exportsToModule: bool): Env =
  Env(
    parent: parent,
    fallback: fallback,
    bindings: initOrderedTable[string, Value](),
    runtimeState: runtimeState,
    currentModule: currentModule,
    exportsToModule: exportsToModule
  )

proc initNativeModuleBuilder*(name: string): NativeModuleBuilder =
  NativeModuleBuilder(name: name, exports: initOrderedTable[string, Value]())

proc command*(builder: var NativeModuleBuilder; name: string; implementation: NativeCommandProc): var NativeModuleBuilder =
  builder.exports[name] = newNativeCommandValue(nativeCommandKind(name: name, implementation: implementation))
  builder

proc value*(builder: var NativeModuleBuilder; name: string; v: Value): var NativeModuleBuilder =
  builder.exports[name] = v
  builder

proc build*(builder: NativeModuleBuilder): NativeModuleDefinition =
  NativeModuleDefinition(name: builder.name, exports: builder.exports)

proc `==`*(a, b: Value): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    return false
  case a.kind
  of Nil:
    true
  of Symbol:
    a.symbolValue == b.symbolValue
  of Text:
    a.textValue == b.textValue
  of Integer:
    a.intValue == b.intValue
  of Real:
    a.realValue == b.realValue
  of Boolean:
    a.boolValue == b.boolValue
  of Sequence:
    if a.items.len != b.items.len:
      return false
    for i in 0 ..< a.items.len:
      if a.items[i] != b.items[i]:
        return false
    true
  of Table:
    if a.entries.len != b.entries.len:
      return false
    for key, value in a.entries.pairs:
      if not b.entries.hasKey(key) or b.entries[key] != value:
        return false
    true
  of Command:
    if a.objects.len != b.objects.len:
      return false
    for i in 0 ..< a.objects.len:
      if a.objects[i] != b.objects[i]:
        return false
    true
  of Script:
    if a.commands.len != b.commands.len:
      return false
    for i in 0 ..< a.commands.len:
      if a.commands[i] != b.commands[i]:
        return false
    true
  of Block:
    if a.blockCommands.len != b.blockCommands.len:
      return false
    for i in 0 ..< a.blockCommands.len:
      if a.blockCommands[i] != b.blockCommands[i]:
        return false
    true
  of MemberAccess:
    a.receiver == b.receiver and a.memberName == b.memberName
  of IndexedAccess:
    a.indexedReceiver == b.indexedReceiver and a.indexValue == b.indexValue
  of Array:
    if a.arity != b.arity or a.elements.len != b.elements.len:
      return false
    for i in 0 ..< a.elements.len:
      if a.elements[i] != b.elements[i]:
        return false
    true
  of StringTemplate:
    if a.templateSegments.len != b.templateSegments.len:
      return false
    for i in 0 ..< a.templateSegments.len:
      if a.templateSegments[i] != b.templateSegments[i]:
        return false
    true
  else:
    cast[pointer](a) == cast[pointer](b)

proc hash*(value: Value): Hash =
  if value.isNil:
    return hash(0)
  result = hash(ord(value.kind))
  case value.kind
  of Nil:
    discard
  of Symbol:
    result = result !& hash(value.symbolValue)
  of Text:
    result = result !& hash(value.textValue)
  of Integer:
    result = result !& hash(value.intValue)
  of Real:
    result = result !& hash(value.realValue)
  of Boolean:
    result = result !& hash(value.boolValue)
  of Sequence:
    for item in value.items:
      result = result !& hash(item)
  of Table:
    for key, item in value.entries.pairs:
      result = result !& hash(key)
      result = result !& hash(item)
  of Command:
    for obj in value.objects:
      result = result !& hash(obj)
  of Script:
    for cmd in value.commands:
      result = result !& hash(cmd)
  of Block:
    for cmd in value.blockCommands:
      result = result !& hash(cmd)
  of MemberAccess:
    result = result !& hash(value.receiver)
    result = result !& hash(value.memberName)
  of IndexedAccess:
    result = result !& hash(value.indexedReceiver)
    result = result !& hash(value.indexValue)
  of Array:
    result = result !& hash(value.arity)
    for item in value.elements:
      result = result !& hash(item)
  of StringTemplate:
    for segment in value.templateSegments:
      case segment.kind
      of Text:
        result = result !& hash(segment.text)
      of Object:
        result = result !& hash(segment.obj)
  else:
    result = result !& hash(cast[int](value))
  result = !$result
