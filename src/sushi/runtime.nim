import std/[math, options, os, sequtils, strformat, strutils, tables]
import builtin_scripts
import diagnostics
import model
import parser

var ctorCallCount* = 0

const
  DotIndexMarker = ":dot-index"

type
  ResolvedValue = object
    value: Value
    env: Env
    hasCapturedEnv: bool

proc formatValue*(value: Value): string
proc evaluate*(evaluator: Evaluator; value: Value; env: Env): Value
proc evaluateQuoted*(evaluator: Evaluator; value: Value; env: Env): Value
proc invokeValue*(value: Value; evaluator: Evaluator; env: Env; args: seq[Value]): Value
proc has*(env: Env; name: Value): bool
proc find*(env: Env; name: Value): Value

proc isDotIndexMarker(value: Value): bool =
  value.kind == Command and value.objects.len == 2 and value.objects[0].kind == Symbol and
    value.objects[0].symbolValue == DotIndexMarker

proc isDotAccessCommand(value: Value): bool =
  value.kind == Command and value.objects.len == 3 and value.objects[0].kind == Symbol and
    value.objects[0].symbolValue == "."

proc formatDotAccess(value: Value): string =
  let receiver = formatValue(value.objects[1])
  let accessor = value.objects[2]
  if accessor.isDotIndexMarker:
    return receiver & ".(" & formatValue(accessor.objects[1]) & ")"
  receiver & "." & formatValue(accessor)

proc captureArgument(arg: Value; env: Env): Value =
  if arg.kind == Symbol and env.has(arg):
    let existing = env.find(arg)
    if existing.kind == CapturedSyntax:
      return existing
  newCapturedSyntax(arg, env)

proc newEvaluator*(): Evaluator =
  Evaluator()

proc push*(env: Env): Env =
  initEnv(env, nil, env.runtimeState, env.currentModule, false)

proc createModuleScope*(env: Env; moduleValue: Value): Env =
  initEnv(env, nil, env.runtimeState, moduleValue, true)

proc createReplayScope*(env, callerScope: Env): Env =
  let baseEnv = if env.isNil: callerScope else: env
  let state =
    if not baseEnv.isNil and not baseEnv.runtimeState.isNil:
      baseEnv.runtimeState
    elif not callerScope.isNil:
      callerScope.runtimeState
    else:
      initRuntimeState()
  let moduleValue =
    if not baseEnv.isNil and not baseEnv.currentModule.isNil:
      baseEnv.currentModule
    elif not callerScope.isNil:
      callerScope.currentModule
    else:
      nil
  let fallbackEnv =
    if callerScope.isNil:
      if baseEnv.isNil: nil else: baseEnv.fallback
    elif baseEnv.isNil or baseEnv.fallback.isNil:
      callerScope
    else:
      initEnv(callerScope, baseEnv.fallback, state, callerScope.currentModule, false)
  result = initEnv(baseEnv, fallbackEnv, state, moduleValue, false)

proc getModuleGlobalScope*(env: Env): Env =
  var last = env
  result = env
  while not result.isNil:
    last = result
    if not result.currentModule.isNil and result.exportsToModule:
      return
    result = result.parent
  result = last

proc exportValue(moduleValue: Value; name: string; value: Value) =
  moduleValue.exports[name] = value

proc define*(env: Env; name, value: Value) =
  env.bindings[name.keyName] = value
  if env.exportsToModule and not env.currentModule.isNil and name.kind == Symbol:
    env.currentModule.exportValue(name.symbolValue, value)

proc tryFind(env: Env; key: string; visited: var seq[Env]): Option[Value] =
  if env.isNil or env in visited:
    return none(Value)
  visited.add(env)
  if env.bindings.hasKey(key):
    return some(env.bindings[key])
  let parentValue = tryFind(env.parent, key, visited)
  if parentValue.isSome:
    return parentValue
  tryFind(env.fallback, key, visited)

proc has*(env: Env; name: Value): bool =
  let key = name.keyName
  var visited: seq[Env]
  tryFind(env, key, visited).isSome

proc find*(env: Env; name: Value): Value =
  let key = name.keyName
  var visited: seq[Env]
  let resolved = tryFind(env, key, visited)
  if resolved.isNone:
    raise newSushiError("Name " & formatValue(name) & " not found in environment.")
  resolved.get

proc setValue*(env: Env; name, value: Value) =
  let key = name.keyName
  if env.bindings.hasKey(key):
    env.bindings[key] = value
    if env.exportsToModule and not env.currentModule.isNil and name.kind == Symbol:
      env.currentModule.exportValue(name.symbolValue, value)
    return
  if not env.parent.isNil and env.parent.has(name):
    env.parent.setValue(name, value)
    return
  if not env.fallback.isNil and env.fallback.has(name):
    env.fallback.setValue(name, value)
    return
  raise newSushiError("Name " & formatValue(name) & " is not defined.")

proc cloneLiteralObject(value: Value): Value

proc cloneLiteralSequence(value: Value): Value =
  newSequence(value.items.mapIt(cloneLiteralObject(it)))

proc cloneLiteralTable(value: Value): Value =
  var entries = initTable[Value, Value]()
  for key, item in value.entries.pairs:
    entries[cloneLiteralObject(key)] = cloneLiteralObject(item)
  newTable(entries)

proc cloneLiteralObject(value: Value): Value =
  case value.kind
  of Sequence:
    cloneLiteralSequence(value)
  of Table:
    cloneLiteralTable(value)
  else:
    value

proc renderTemplateValue(value: Value): string =
  if value.kind == Text: value.textValue else: formatValue(value)

proc evaluateStringTemplate(evaluator: Evaluator; tmpl: Value; env: Env): Value =
  var buffer = ""
  for segment in tmpl.templateSegments:
    case segment.kind
    of Text:
      buffer.add(segment.text)
    of Object:
      buffer.add(renderTemplateValue(evaluator.evaluateQuoted(segment.obj, env)))
  newText(buffer, tmpl.span)

proc evaluateScript*(evaluator: Evaluator; script: Value; env: Env): Value =
  result = newNilValue()
  for command in script.commands:
    result = evaluator.evaluate(command, env)

proc topLevelSourceValue(source: SourceFile): Value =
  let script = parseScript(source)
  if script.commands.len == 1:
    let command = script.commands[0]
    if command.kind == Command and command.objects.len == 1:
      return command.objects[0]
    return command
  script

proc evaluateBlock*(evaluator: Evaluator; blockValue: Value; env: Env): Value =
  result = newNilValue()
  for command in blockValue.blockCommands:
    result = evaluator.evaluate(command, env)

proc getExport*(moduleValue: Value; memberName: string): Value =
  if moduleValue.exports.hasKey(memberName):
    return moduleValue.exports[memberName]
  raise newSushiError("moduleKind " & moduleValue.moduleName & " does not export " & memberName & ".")

proc hasField(classDef: ClassDef; fieldName: string): bool =
  fieldName in classDef.declaredFields or (not classDef.baseClass.isNil and classDef.baseClass.hasField(fieldName))

proc getFieldDefault(classDef: ClassDef; fieldName: string): Value =
  if classDef.fieldDefaults.hasKey(fieldName):
    return classDef.fieldDefaults[fieldName]
  if not classDef.baseClass.isNil:
    return classDef.baseClass.getFieldDefault(fieldName)
  newNilValue()

proc enumerateAllFields(classDef: ClassDef): seq[string] =
  if not classDef.baseClass.isNil:
    result.add(classDef.baseClass.enumerateAllFields)
  result.add(classDef.declaredFields)

proc getInstanceMethod(classDef: ClassDef; methodName: string): MethodDef =
  if classDef.instanceMethods.hasKey(methodName):
    return classDef.instanceMethods[methodName]
  if not classDef.baseClass.isNil:
    return classDef.baseClass.getInstanceMethod(methodName)
  nil

proc getClassMethod(classDef: ClassDef; methodName: string): MethodDef =
  if classDef.classMethods.hasKey(methodName):
    return classDef.classMethods[methodName]
  if not classDef.baseClass.isNil:
    return classDef.baseClass.getClassMethod(methodName)
  nil

proc createInstance(classDef: ClassDef): instanceKind =
  result = instanceKind(`class`: classDef, fields: initOrderedTable[string, Value]())
  for fieldName in classDef.enumerateAllFields():
    result.fields[fieldName] = classDef.getFieldDefault(fieldName)

proc hasField(instance: instanceKind; fieldName: string): bool =
  instance.fields.hasKey(fieldName)

proc getField(instance: instanceKind; fieldName: string): Value =
  if not instance.fields.hasKey(fieldName):
    raise newSushiError("Field " & fieldName & " is not defined on class " & instance.class.name & ".")
  instance.fields[fieldName]

proc setField(instance: instanceKind; fieldName: string; value: Value) =
  if not instance.fields.hasKey(fieldName):
    raise newSushiError("Field " & fieldName & " is not defined on class " & instance.class.name & ".")
  instance.fields[fieldName] = value

proc invokeMethod(mdef: MethodDef; evaluator: Evaluator; instance: instanceKind; args: seq[Value];
    callerEnv: Env = nil): Value

proc formatInstance(instance: instanceKind): string =
  let toStringMethod = instance.class.getInstanceMethod("to-string")
  if not toStringMethod.isNil:
    let rendered = invokeMethod(toStringMethod, newEvaluator(), instance, @[])
    return if rendered.kind == Text: rendered.textValue else: formatValue(rendered)
  var parts: seq[string]
  for key, value in instance.fields.pairs:
    parts.add(key & " " & (if value.isNil or value.kind == Nil: "<unset>" else: formatValue(value)))
  instance.class.name & " {" & parts.join(" ") & "}"

proc formatValue*(value: Value): string =
  if value.isNil:
    return ""
  case value.kind
  of Nil:
    ""
  of Symbol:
    value.symbolValue
  of Text:
    "\"" & value.textValue.multiReplace(("\\", "\\\\"), ("\"", "\\\""), ("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")) & "\""
  of StringTemplate:
    var resultText = "\""
    for segment in value.templateSegments:
      case segment.kind
      of Text:
        resultText.add(segment.text.multiReplace(("\\", "\\\\"), ("\"", "\\\""), ("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")))
      of Object:
        resultText.add("\\(" & formatValue(segment.obj) & ")")
    resultText.add('"')
    resultText
  of Integer:
    $value.intValue
  of Real:
    $value.realValue
  of Boolean:
    if value.boolValue: "T" else: "F"
  of Sequence:
    "#[" & value.items.map(formatValue).join(" ") & "]"
  of Table:
    var parts: seq[string]
    for key, item in value.entries.pairs:
      parts.add(formatValue(key))
      parts.add(formatValue(item))
    "{" & parts.join(" ") & "}"
  of Command:
    if value.isDotAccessCommand:
      formatDotAccess(value)
    else:
      value.objects.map(formatValue).join(" ")
  of Script:
    value.commands.map(formatValue).filterIt(it.len > 0).join("\n")
  of Block:
    if value.blockCommands.len == 0:
      "do\nend"
    else:
      "do\n" & value.blockCommands.map(formatValue).join("\n") & "\nend"
  of Instance:
    formatInstance(value.instanceDef)
  of Array:
    "[array(" & $value.elements.len & ")]"
  of Module:
    "<module:" & value.moduleName & ">"
  of Class:
    "<class:" & value.classDef.name & ">"
  of NativeCommand:
    "<native:" & value.nativeCommand.name & ">"
  of UserCommand:
    "<fun:" & value.userCommand.name & ">"
  of Method:
    "<method:" & value.methodDef.name & ">"
  of CapturedSyntax:
    formatValue(value.capturedValue)

proc isTruthy(value: Value): bool =
  not (value.kind == Boolean and not value.boolValue)

proc evaluateTableIndex(tableValue, index: Value): Value =
  if tableValue.entries.hasKey(index):
    return tableValue.entries[index]
  raise newSushiError("tableKind key " & formatValue(index) & " is not defined.")

proc evaluateSequenceIndex(sequenceValue, index: Value): Value =
  if index.kind != Integer:
    raise newSushiError("Indexed access on a list expects an integer index.")
  if index.intValue < 0 or index.intValue >= sequenceValue.items.len:
    raise newSushiError("List index " & $index.intValue & " is out of range.")
  sequenceValue.items[index.intValue]

proc evaluateArrayIndex(arrayValue, index: Value): Value =
  if index.kind != Integer:
    raise newSushiError("arrayKind index must be an integer.")
  if index.intValue < 0 or index.intValue >= arrayValue.elements.len:
    raise newSushiError("arrayKind index " & $index.intValue & " out of range.")
  arrayValue.elements[index.intValue]

proc invokeMethod(mdef: MethodDef; evaluator: Evaluator; classDef: ClassDef; args: seq[Value];
    callerEnv: Env = nil): Value =
  let callEnv = mdef.definingEnv.push
  callEnv.define(newSymbol("Self"), newClassValue(classDef))
  if mdef.variadic:
    if mdef.parameters.len != 1 or mdef.parameters[0].kind != Symbol:
      raise newSushiError("Variadic method " & mdef.declaringClass.name & "." & mdef.name &
        " must declare exactly one symbol parameter.")
    let capturedArgs =
      if callerEnv.isNil:
        args
      else:
        args.mapIt(captureArgument(it, callerEnv))
    callEnv.define(newSymbol(mdef.parameters[0].symbolValue), newSequence(capturedArgs))
  else:
    let required = mdef.parameters.countIt(it.kind == Symbol)
    if args.len < required or args.len > mdef.parameters.len:
      raise newSushiError("methodKind " & mdef.declaringClass.name & "." & mdef.name &
        " expected " & $required & "–" & $mdef.parameters.len & " argument(s), got " & $args.len & ".")
    for i, parameter in mdef.parameters:
      if parameter.kind == Symbol:
        let value = if i < args.len: (if callerEnv.isNil: args[i] else: captureArgument(args[i], callerEnv)) else: newNilValue()
        callEnv.define(newSymbol(parameter.symbolValue), value)
      else:
        let paramName = parameter.objects[0]
        let defaultExpr = parameter.objects[1]
        let value = if i < args.len: (if callerEnv.isNil: args[i] else: captureArgument(args[i], callerEnv))
          else: evaluator.evaluateQuoted(defaultExpr, mdef.definingEnv)
        callEnv.define(paramName, value)
  evaluator.evaluateBlock(mdef.body, callEnv)

proc invokeMethod(mdef: MethodDef; evaluator: Evaluator; instance: instanceKind; args: seq[Value];
    callerEnv: Env = nil): Value =
  let callEnv = mdef.definingEnv.push
  callEnv.define(newSymbol("self"), newInstanceValue(instance))
  callEnv.define(newSymbol("Self"), newClassValue(instance.class))
  let superMethod = if mdef.declaringClass.baseClass.isNil: nil else: mdef.declaringClass.baseClass.getInstanceMethod(mdef.name)
  if not superMethod.isNil:
    callEnv.define(newSymbol(mdef.name), newNativeCommandValue(nativeCommandKind(
      name: mdef.name,
      implementation: proc (ev: Evaluator; superEnv: Env; superArgs: seq[Value]): Value =
        invokeMethod(superMethod, ev, instance, superArgs, superEnv)
    )))
  if mdef.variadic:
    if mdef.parameters.len != 1 or mdef.parameters[0].kind != Symbol:
      raise newSushiError("Variadic method " & mdef.declaringClass.name & "." & mdef.name &
        " must declare exactly one symbol parameter.")
    let capturedArgs =
      if callerEnv.isNil:
        args
      else:
        args.mapIt(captureArgument(it, callerEnv))
    callEnv.define(newSymbol(mdef.parameters[0].symbolValue), newSequence(capturedArgs))
  else:
    let required = mdef.parameters.countIt(it.kind == Symbol)
    if args.len < required or args.len > mdef.parameters.len:
      raise newSushiError("methodKind " & mdef.declaringClass.name & "." & mdef.name &
        " expected " & $required & "–" & $mdef.parameters.len & " argument(s), got " & $args.len & ".")
    for i, parameter in mdef.parameters:
      if parameter.kind == Symbol:
        let value = if i < args.len: (if callerEnv.isNil: args[i] else: captureArgument(args[i], callerEnv)) else: newNilValue()
        callEnv.define(newSymbol(parameter.symbolValue), value)
      else:
        let paramName = parameter.objects[0]
        let defaultExpr = parameter.objects[1]
        let value = if i < args.len: (if callerEnv.isNil: args[i] else: captureArgument(args[i], callerEnv))
          else: evaluator.evaluateQuoted(defaultExpr, mdef.definingEnv)
        callEnv.define(paramName, value)
  evaluator.evaluateBlock(mdef.body, callEnv)

proc evaluateDotAccess(evaluator: Evaluator; dotAccess: Value; args: seq[Value]; env: Env): Value =
  if not dotAccess.isDotAccessCommand:
    raise newSushiError("Invalid dot access.")
  let receiver = evaluator.evaluateQuoted(dotAccess.objects[1], env)
  let accessor = dotAccess.objects[2]
  try:
    if accessor.isDotIndexMarker:
      let indexValue = evaluator.evaluateQuoted(accessor.objects[1], env)
      case receiver.kind
      of Table:
        return evaluateTableIndex(receiver, indexValue)
      of Sequence:
        return evaluateSequenceIndex(receiver, indexValue)
      of Array:
        return evaluateArrayIndex(receiver, indexValue)
      else:
        raise newSushiError("objectSegment " & formatValue(receiver) & " does not support indexing.")
    if accessor.kind != Symbol:
      raise newSushiError("Dot access expects a member name or grouped index.")
    case receiver.kind
    of Table:
      if args.len != 0:
        raise newSushiError("tableKind values are not invokable.")
      return evaluateTableIndex(receiver, accessor)
    of Module:
      let exported = receiver.getExport(accessor.symbolValue)
      if args.len == 0 and not exported.isCallable:
        return exported
      invokeValue(exported, evaluator, env, args)
    of Instance:
      if args.len == 0 and receiver.instanceDef.hasField(accessor.symbolValue):
        return receiver.instanceDef.getField(accessor.symbolValue)
      let mdef = receiver.instanceDef.class.getInstanceMethod(accessor.symbolValue)
      if mdef.isNil:
        raise newSushiError("methodKind " & receiver.instanceDef.class.name & "." & accessor.symbolValue & " is not defined.")
      invokeMethod(mdef, evaluator, receiver.instanceDef, args, env)
    of Class:
      let mdef = receiver.classDef.getClassMethod(accessor.symbolValue)
      if mdef.isNil:
        raise newSushiError("classKind method " & receiver.classDef.name & "." & accessor.symbolValue & " is not defined.")
      if args.len == 0:
        return newMethodValue(mdef)
      invokeMethod(mdef, evaluator, receiver.classDef, args, env)
    else:
      raise newSushiError("objectSegment " & formatValue(receiver) & " does not support member access.")
  except CatchableError as err:
    raise wrapSushiError(err, dotAccess.span)

proc invokeValue*(value: Value; evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  case value.kind
  of NativeCommand:
    value.nativeCommand.implementation(evaluator, env, args)
  of UserCommand:
    let callEnv = value.userCommand.definingEnv.push
    if value.userCommand.variadic:
      if value.userCommand.parameters.len != 1 or value.userCommand.parameters[0].kind != Symbol:
        raise newSushiError("Variadic command " & value.userCommand.name & " must declare exactly one symbol parameter.")
      callEnv.define(newSymbol(value.userCommand.parameters[0].symbolValue), newSequence(args.mapIt(captureArgument(it, env))))
    else:
      let required = value.userCommand.parameters.countIt(it.kind == Symbol)
      if args.len < required or args.len > value.userCommand.parameters.len:
        raise newSushiError("commandKind " & value.userCommand.name & " expected " & $required & "–" &
          $value.userCommand.parameters.len & " argument(s), got " & $args.len & ".")
      for i, parameter in value.userCommand.parameters:
        if parameter.kind == Symbol:
          let boundValue = if i < args.len: captureArgument(args[i], env) else: newNilValue()
          callEnv.define(newSymbol(parameter.symbolValue), boundValue)
        else:
          let paramName = parameter.objects[0]
          let defaultExpr = parameter.objects[1]
          let boundValue = if i < args.len: captureArgument(args[i], env)
            else: evaluator.evaluateQuoted(defaultExpr, value.userCommand.definingEnv)
          callEnv.define(paramName, boundValue)
    evaluator.evaluateBlock(value.userCommand.body, callEnv)
  of Method:
    if value.methodDef.isClassMethod:
      invokeMethod(value.methodDef, evaluator, value.methodDef.declaringClass, args, env)
    else:
      raise newSushiError("Cannot invoke instance method without a receiver.")
  else:
    raise newSushiError("objectSegment " & formatValue(value) & " is not invokable.")

proc evaluateQuoted*(evaluator: Evaluator; value: Value; env: Env): Value =
  case value.kind
  of CapturedSyntax:
    evaluator.evaluateQuoted(value.capturedValue, value.capturedEnv)
  of Sequence:
    if value.span.isEmpty: value else: cloneLiteralSequence(value)
  of Table:
    if value.span.isEmpty: value else: cloneLiteralTable(value)
  of StringTemplate:
    evaluateStringTemplate(evaluator, value, env)
  of Command:
    if value.isDotAccessCommand:
      evaluator.evaluateDotAccess(value, @[], env)
    else:
      evaluator.evaluate(value, env)
  of Block:
    evaluator.evaluateBlock(value, env.push)
  of Symbol:
    if env.has(value):
      evaluator.evaluateQuoted(env.find(value), env)
    else:
      value
  else:
    value

proc isLambdaLiteral(value: Value): bool =
  value.kind == Command and value.objects.len == 3 and
    value.objects[0].kind == Symbol and value.objects[0].symbolValue == "fn"

proc evaluate*(evaluator: Evaluator; value: Value; env: Env): Value =
  try:
    case value.kind
    of Script:
      evaluator.evaluateScript(value, env)
    of Command:
      if value.objects.len == 0:
        raise newSushiError("Cannot evaluate an empty command.")
      if value.objects.len == 1:
        let head = value.objects[0]
        case head.kind
        of Command:
          if head.isLambdaLiteral:
            return evaluator.evaluate(head, env)
          if head.isDotAccessCommand:
            return evaluator.evaluateDotAccess(head, @[], env)
        of StringTemplate:
          return evaluator.evaluateQuoted(head, env)
        of Symbol:
          if env.has(head):
            let found = env.find(head)
            if found.isCallable:
              return invokeValue(found, evaluator, env, @[])
        else:
          discard
        return head
      let args = value.objects[1 .. ^1]
      if value.objects[0].isDotAccessCommand:
        return evaluator.evaluateDotAccess(value.objects[0], args, env)
      if value.objects[0].kind != Symbol:
        raise newSushiError("commandKind head must be a symbol, got " & formatValue(value.objects[0]) & ".")
      if not env.has(value.objects[0]):
        raise newSushiError("Unknown command: " & formatValue(value.objects[0]))
      let callable = env.find(value.objects[0])
      invokeValue(callable, evaluator, env, args)
    else:
      value
  except CatchableError as err:
    raise wrapSushiError(err, value.span)

proc evaluateSource*(evaluator: Evaluator; source: SourceFile; env: Env): Value =
  evaluator.evaluate(parseScript(source), env)

proc evaluateSource*(evaluator: Evaluator; source, sourceName: string; env: Env): Value =
  evaluator.evaluateSource(newSourceFile(sourceName, source), env)

proc resolveScriptPath*(fileName: string): string =
  let candidates = @[
    getCurrentDir() / "scripts" / fileName,
    getAppDir() / "scripts" / fileName
  ]
  for candidate in candidates:
    let fullPath = candidate.normalizedPath
    if fileExists(fullPath):
      return fullPath
  raise newException(IOError, "Could not find Sushi script '" & fileName & "'.")

proc resolveModulePath*(moduleName, importerFilePath: string): string =
  let fileName = if moduleName.endsWith(".sushi"): moduleName else: moduleName & ".sushi"
  var candidates: seq[string]
  if importerFilePath.len > 0:
    let importerDir = splitFile(importerFilePath).dir
    if importerDir.len > 0:
      candidates.add(importerDir / fileName)
  candidates.add(getCurrentDir() / fileName)
  candidates.add(getCurrentDir() / "scripts" / fileName)
  candidates.add(getAppDir() / "scripts" / fileName)
  for candidate in candidates:
    let fullPath = candidate.normalizedPath
    if fileExists(fullPath):
      return fullPath
  raise newException(IOError, "Could not find Sushi module '" & moduleName & "'.")

proc registerNativeModule*(state: RuntimeState; moduleValue: Value) =
  if state.nativeModulesByName.hasKey(moduleValue.moduleName):
    raise newException(ValueError, "A native module named '" & moduleValue.moduleName & "' is already registered.")
  state.nativeModulesByName[moduleValue.moduleName] = moduleValue

proc loadModuleBySource(state: RuntimeState; moduleName, sourceName, sourceText: string; evaluator: Evaluator): Value =
  if sourceName in state.loadingModules:
    raise newSushiError("Cyclic module import detected for " & moduleName & ".")
  if state.modulesByPath.hasKey(sourceName):
    return state.modulesByPath[sourceName]
  state.loadingModules.add(sourceName)
  try:
    let moduleValue = newModuleValue(moduleName, sourceName)
    let moduleEnv = state.rootEnv.createModuleScope(moduleValue)
    state.modulesByPath[sourceName] = moduleValue
    let source = newSourceFile(sourceName, sourceText)
    moduleValue.lastResult = evaluator.evaluateSource(source, moduleEnv)
    return moduleValue
  except:
    state.modulesByPath.del(sourceName)
    raise
  finally:
    state.loadingModules.keepItIf(it != sourceName)

proc loadModuleByPath(state: RuntimeState; moduleName, fullPath: string; evaluator: Evaluator): Value =
  let normalized = fullPath.normalizedPath
  state.loadModuleBySource(moduleName, normalized, readFile(normalized), evaluator)

proc loadModule*(state: RuntimeState; moduleName, importerFilePath: string; evaluator: Evaluator): Value =
  if state.nativeModulesByName.hasKey(moduleName):
    return state.nativeModulesByName[moduleName]
  let embeddedModule = findEmbeddedModule(moduleName)
  if embeddedModule.isSome:
    let script = embeddedModule.get
    return state.loadModuleBySource(moduleName, script.sourceName, script.source, evaluator)
  state.loadModuleByPath(moduleName, resolveModulePath(moduleName, importerFilePath), evaluator)

proc loadEntryModule*(state: RuntimeState; filePath: string; evaluator: Evaluator): Value =
  let fullPath = filePath.normalizedPath
  state.loadModuleByPath(splitFile(fullPath).name, fullPath, evaluator)

proc readParameters(value: Value): seq[Value] =
  if value.kind != Command:
    raise newSushiError("Function parameters must be a bracketed command like [a b] or [a [b 2]].")
  var seenOptional = false
  for parameter in value.objects:
    case parameter.kind
    of Symbol:
      if seenOptional:
        raise newSushiError("Required parameters cannot follow optional parameters.")
      result.add(parameter)
    of Command:
      if parameter.objects.len == 2 and parameter.objects[0].kind == Symbol:
        seenOptional = true
        result.add(parameter)
      else:
        raise newSushiError("Optional parameter must be [name default].")
    else:
      raise newSushiError("Optional parameter must be [name default].")

proc requireBlock(value: Value): Value =
  if value.kind != Block:
    raise newSushiError("Function body must be a block.")
  value

proc normalizeCallableBody(value: Value): Value =
  case value.kind
  of Block:
    value
  of Command:
    if value.objects.len == 1 and value.objects[0].kind == Command:
      newBlock(@[value.objects[0]], value.span)
    else:
      newBlock(@[value], value.span)
  else:
    raise newSushiError("Lambda body must be a command or block.")

proc readMethodName(value: Value): tuple[name: string, isClassMethod: bool] =
  case value.kind
  of Symbol:
    if '.' in value.symbolValue:
      let parts = value.symbolValue.split('.')
      if parts.len == 2 and parts[0] == "Self":
        return (parts[1], true)
      raise newSushiError("Only Self.method syntax is supported for class methods.")
    (value.symbolValue, false)
  of Command:
    if value.isDotAccessCommand and value.objects[1].kind == Symbol and value.objects[1].symbolValue == "Self" and
        value.objects[2].kind == Symbol:
      (value.objects[2].symbolValue, true)
    else:
      raise newSushiError("Only Self.method syntax is supported for class methods.")
  else:
    raise newSushiError("methodKind name must be a symbol or member access.")

proc resolveBaseClass(inheritanceSpec: Value; env: Env): ClassDef =
  if inheritanceSpec.kind != Command:
    raise newSushiError("classKind inheritance must be provided as a bracketed command.")
  if inheritanceSpec.objects.len == 0:
    return nil
  if inheritanceSpec.objects.len != 1 or inheritanceSpec.objects[0].kind != Symbol:
    raise newSushiError("classKind inheritance must specify zero or one base class.")
  if not env.has(inheritanceSpec.objects[0]):
    raise newSushiError("Base class " & inheritanceSpec.objects[0].symbolValue & " is not defined.")
  let baseValue = env.find(inheritanceSpec.objects[0])
  if baseValue.kind != Class:
    raise newSushiError(inheritanceSpec.objects[0].symbolValue & " is not a class.")
  baseValue.classDef

proc declareField(classDef: ClassDef; fieldName: string; defaultValue = newNilValue()) =
  if classDef.hasField(fieldName):
    raise newSushiError("Field " & fieldName & " is already defined on class " & classDef.name & ".")
  classDef.declaredFields.add(fieldName)
  if defaultValue.kind != Nil:
    classDef.fieldDefaults[fieldName] = defaultValue

proc defineMethod(classDef: ClassDef; mdef: MethodDef) =
  if mdef.isClassMethod:
    classDef.classMethods[mdef.name] = mdef
  else:
    classDef.instanceMethods[mdef.name] = mdef

proc defineFields(classDef: ClassDef; command: Value; evaluator: Evaluator; env: Env) =
  if command.objects.len < 2:
    raise newSushiError("Field declaration requires at least one field name.")
  if command.objects.len == 2 and command.objects[1].kind == Table:
    for key, item in command.objects[1].entries.pairs:
      if key.kind != Symbol:
        raise newSushiError("Field names in a field table must be symbols.")
      classDef.declareField(key.symbolValue, evaluator.evaluateQuoted(item, env))
    return
  for fieldObject in command.objects[1 .. ^1]:
    if fieldObject.kind != Symbol:
      raise newSushiError("Field names must be symbols.")
    classDef.declareField(fieldObject.symbolValue)

proc defineClassMethod(classDef: ClassDef; command: Value) =
  let args = command.objects[1 .. ^1]
  if args.len < 2 or args.len > 3:
    raise newSushiError("methodKind declaration expects 'fun name [params] do ... end', 'fun name args do ... end', or 'fun name do ... end'.")
  let variadic = args.len == 3 and args[1].kind == Symbol
  let parameters =
    if args.len == 2: @[]
    elif variadic: @[args[1]]
    else: readParameters(args[1])
  let body = requireBlock(args[^1])
  let (methodName, isClassMethod) = readMethodName(args[0])
  classDef.defineMethod(MethodDef(
    name: methodName,
    parameters: parameters,
    body: body,
    definingEnv: classDef.definingEnv,
    declaringClass: classDef,
    isClassMethod: isClassMethod,
    variadic: variadic
  ))

proc defineClassMember(classDef: ClassDef; command: Value; evaluator: Evaluator; env: Env) =
  if command.objects.len == 0:
    return
  if command.objects[0].kind != Symbol:
    raise newSushiError("classKind body command head must be a symbol.")
  case command.objects[0].symbolValue
  of "field":
    defineFields(classDef, command, evaluator, env)
  of "fun":
    defineClassMethod(classDef, command)
  else:
    raise newSushiError("Unsupported class body command: " & command.objects[0].symbolValue & ".")

proc resolveRawSymbol(symbol: Value; env: Env): Value

proc resolveRawValueWithCapture(value: Value; evaluator: Evaluator; env: Env): ResolvedValue =
  var seenSymbols: seq[string]
  var current = value
  var currentEnv = env
  var hasCaptured = false
  while true:
    case current.kind
    of CapturedSyntax:
      let capturedValue = current.capturedValue
      let capturedEnv = current.capturedEnv
      current = capturedValue
      currentEnv = capturedEnv
      hasCaptured = true
    of Symbol:
      if currentEnv.has(current):
        if current.symbolValue in seenSymbols:
          raise newSushiError("Recursive raw value resolution for " & current.symbolValue & ".")
        seenSymbols.add(current.symbolValue)
        current = resolveRawSymbol(current, currentEnv)
      else:
        return ResolvedValue(value: current, env: currentEnv, hasCapturedEnv: hasCaptured)
    of Command:
      if current.isDotAccessCommand:
        current = evaluator.evaluateDotAccess(current, @[], currentEnv)
      else:
        return ResolvedValue(value: current, env: currentEnv, hasCapturedEnv: hasCaptured)
    else:
      return ResolvedValue(value: current, env: currentEnv, hasCapturedEnv: hasCaptured)

proc resolveRawValue*(value: Value; evaluator: Evaluator; env: Env): Value =
  resolveRawValueWithCapture(value, evaluator, env).value

proc capturedEnv*(value: Value; evaluator: Evaluator; env: Env): Env =
  let resolved = resolveRawValueWithCapture(value, evaluator, env)
  if resolved.hasCapturedEnv and not resolved.env.isNil:
    resolved.env
  else:
    env

proc findCapturedSyntax(value: Value; env: Env): Value =
  var seenSymbols: seq[string]
  var current = value
  var currentEnv = env
  while true:
    case current.kind
    of CapturedSyntax:
      return current
    of Symbol:
      if currentEnv.has(current):
        if current.symbolValue in seenSymbols:
          raise newSushiError("Recursive captured syntax resolution for " & current.symbolValue & ".")
        seenSymbols.add(current.symbolValue)
        current = currentEnv.find(current)
      else:
        return nil
    else:
      return nil

proc evaluateQuotedWithCapture(value: Value; evaluator: Evaluator; env: Env): ResolvedValue =
  let captured = findCapturedSyntax(value, env)
  if captured.isNil:
    return ResolvedValue(value: evaluator.evaluateQuoted(value, env), env: env, hasCapturedEnv: false)
  ResolvedValue(value: evaluator.evaluateQuoted(captured.capturedValue, captured.capturedEnv),
    env: captured.capturedEnv, hasCapturedEnv: true)

proc preserveCapture(value: Value; resolved: ResolvedValue): Value =
  if resolved.hasCapturedEnv: newCapturedSyntax(value, resolved.env) else: value

proc resolveRawSymbol(symbol: Value; env: Env): Value =
  if env.has(symbol):
    let value = env.find(symbol)
    if value.kind == Symbol and value.symbolValue == symbol.symbolValue:
      symbol
    else:
      value
  else:
    symbol

proc buildArray(dimensions: seq[int]; dimIndex: int): Value =
  let size = dimensions[dimIndex]
  var elements = newSeq[Value](size)
  if dimIndex == dimensions.high:
    for i in 0 ..< size:
      elements[i] = newInteger(0)
  else:
    for i in 0 ..< size:
      elements[i] = buildArray(dimensions, dimIndex + 1)
  newArray(elements, dimensions.len - dimIndex)

proc readNumericValue(value: Value): float =
  case value.kind
  of Integer:
    float(value.intValue)
  of Real:
    value.realValue
  else:
    raise newSushiError("Expected numeric argument, got " & formatValue(value) & ".")

proc unwrapSequenceLike(value: Value): Value =
  if value.kind == Command and value.objects.len == 1 and value.objects[0].kind == Sequence:
    value.objects[0]
  else:
    value

proc bindNativeCommands(env: Env)

proc createRootEnv*(runtimeState = initRuntimeState()): Env =
  let env = initEnv(nil, nil, runtimeState, nil, false)
  bindNativeCommands(env)
  runtimeState.rootEnv = env
  env

proc ifCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len < 2 or args.len > 3:
    raise newSushiError("Native command 'if' requires a condition block pair and optional else block.")
  let condition = evaluator.evaluateQuoted(args[0], env)
  let thenBlock = requireBlock(args[1])
  let elseBlock = if args.len == 3: args[2] else: nil
  if isTruthy(condition):
    evaluator.evaluateBlock(thenBlock, env.push)
  elif not elseBlock.isNil:
    evaluator.evaluateBlock(requireBlock(elseBlock), env.push)
  else:
    newBoolean(false)

proc condCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'cond' expects a single block argument.")
  let branchState = resolveRawValueWithCapture(args[0], evaluator, env)
  if branchState.value.kind != Block:
    raise newSushiError("Native command 'cond' expects a block.")
  let branchEnv =
    if branchState.hasCapturedEnv and not branchState.env.isNil:
      branchState.env.createReplayScope(env)
    else:
      env
  for branch in branchState.value.blockCommands:
    if branch.kind != Command or branch.objects.len != 1:
      raise newSushiError("cond branch must have the form '(condition): value'", branch.span)
    let pair = resolveRawValue(branch.objects[0], evaluator, branchEnv)
    if pair.kind != Sequence or pair.items.len != 2:
      raise newSushiError("cond branch must have the form '(condition): value'", branch.span)
    if isTruthy(evaluator.evaluateQuoted(pair.items[0], branchEnv)):
      return evaluator.evaluateQuoted(pair.items[1], branchEnv)
  newBoolean(false)

proc whileCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'while' expects a condition and a body block.")
  let bodyState = resolveRawValueWithCapture(args[1], evaluator, env)
  if bodyState.value.kind != Block:
    raise newSushiError("Native command 'while' expects a block as its second argument.")
  var loopResult = newBoolean(false)
  while isTruthy(evaluator.evaluateQuoted(args[0], env)):
    let bodyEnv =
      if bodyState.hasCapturedEnv and not bodyState.env.isNil:
        bodyState.env.createReplayScope(env)
      else:
        env.push
    loopResult = evaluator.evaluateBlock(bodyState.value, bodyEnv)
  loopResult

proc letCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 3 or args[0].kind != Symbol:
    raise newSushiError("Native command 'let' expects 'let name value do ... end'.")
  let child = env.push
  child.define(args[0], evaluator.evaluateQuoted(args[1], env))
  evaluator.evaluateBlock(requireBlock(args[2]), child)

proc varCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2 or args[0].kind != Symbol:
    raise newSushiError("Native command 'var' expects exactly two arguments.")
  let value = evaluator.evaluateQuoted(args[1], env)
  env.define(args[0], value)
  value

proc setCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'set' expects exactly two arguments.")
  let value = evaluator.evaluateQuoted(args[1], env)
  case args[0].kind
  of Symbol:
    env.setValue(args[0], value)
  of Command:
    if not args[0].isDotAccessCommand:
      raise newSushiError("Invalid set target.")
    let receiver = evaluator.evaluateQuoted(args[0].objects[1], env)
    let accessor = args[0].objects[2]
    if accessor.isDotIndexMarker:
      let indexValue = evaluator.evaluateQuoted(accessor.objects[1], env)
      case receiver.kind
      of Table:
        receiver.entries[indexValue] = value
      of Sequence:
        if indexValue.kind != Integer or indexValue.intValue < 0 or indexValue.intValue >= receiver.items.len:
          raise newSushiError("List index is out of range.")
        receiver.items[indexValue.intValue] = value
      of Array:
        if indexValue.kind != Integer or indexValue.intValue < 0 or indexValue.intValue >= receiver.elements.len:
          raise newSushiError("arrayKind index is out of range.")
        receiver.elements[indexValue.intValue] = value
      else:
        raise newSushiError("Only tables, lists, and arrays can be assigned with indexed set.")
    elif accessor.kind == Symbol:
      if receiver.kind != Instance:
        raise newSushiError("Only instance fields can be assigned with set.")
      receiver.instanceDef.setField(accessor.symbolValue, value)
    else:
      raise newSushiError("Invalid set target.")
  else:
    raise newSushiError("Invalid set target.")
  value

proc evalCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'eval' requires exactly one argument.")
  evaluator.evaluateQuoted(args[0], env)

proc evalValueCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'eval-value' requires exactly one argument.")
  resolveRawValue(args[0], evaluator, env)

proc rawCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'raw' requires exactly one argument.")
  resolveRawValue(args[0], evaluator, env)

proc captureCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  discard evaluator
  if args.len != 1:
    raise newSushiError("Native command 'capture' requires exactly one argument.")
  if args[0].kind == Symbol and env.has(args[0]):
    let existing = env.find(args[0])
    if existing.kind == CapturedSyntax:
      return existing
  newCapturedSyntax(args[0], env)

proc captureSourceCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'capture-source' requires exactly one argument.")
  let source = evaluator.evaluateQuoted(args[0], env)
  if source.kind != Text:
    raise newSushiError("Native command 'capture-source' expects text.")
  newCapturedSyntax(topLevelSourceValue(newSourceFile("<input>", source.textValue)), env)

proc replayCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'replay' requires exactly one argument.")
  var resolved = resolveRawValueWithCapture(args[0], evaluator, env)
  var replayDepth = 0
  while resolved.value.kind != Block and resolved.hasCapturedEnv and not resolved.env.isNil and replayDepth < 8:
    let nextResolved = resolveRawValueWithCapture(resolved.value, evaluator, resolved.env)
    if nextResolved.value == resolved.value and nextResolved.env == resolved.env:
      break
    resolved = nextResolved
    inc replayDepth
  if resolved.value.kind != Block:
    raise newSushiError("Native command 'replay' expects a block.")
  let targetEnv =
    if resolved.hasCapturedEnv and not resolved.env.isNil:
      resolved.env.createReplayScope(env)
    else:
      env.push
  evaluator.evaluateBlock(resolved.value, targetEnv)

proc eqCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'eq' requires exactly two arguments.")
  newBoolean(evaluator.evaluateQuoted(args[0], env) == evaluator.evaluateQuoted(args[1], env))

proc notCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'not' requires exactly one argument.")
  newBoolean(not isTruthy(evaluator.evaluateQuoted(args[0], env)))

proc andCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'and' requires exactly two arguments.")
  let left = evaluator.evaluateQuoted(args[0], env)
  if not isTruthy(left):
    return newBoolean(false)
  newBoolean(isTruthy(evaluator.evaluateQuoted(args[1], env)))

proc orCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'or' requires exactly two arguments.")
  let left = evaluator.evaluateQuoted(args[0], env)
  if isTruthy(left):
    return newBoolean(true)
  newBoolean(isTruthy(evaluator.evaluateQuoted(args[1], env)))

proc writeCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'write' requires exactly one argument.")
  let value = evaluator.evaluateQuoted(args[0], env)
  stdout.write(if value.kind == Text: value.textValue else: formatValue(value))
  value

proc writeLineCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len == 0:
    echo ""
    return newText("")
  let value = evaluator.evaluateQuoted(args[0], env)
  echo(if value.kind == Text: value.textValue else: formatValue(value))
  value

proc readLineCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  discard evaluator
  discard env
  if args.len != 0:
    raise newSushiError("Native command 'read-line' does not take arguments.")
  try:
    newText(stdin.readLine())
  except EOFError:
    newBoolean(false)

proc errorCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'error' requires exactly one argument.")
  let message = evaluator.evaluateQuoted(args[0], env)
  raise newSushiError(if message.kind == Text: message.textValue else: formatValue(message))

proc errorAtCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'error-at' requires exactly two arguments.")
  let target = resolveRawValue(args[0], evaluator, env)
  let message = evaluator.evaluateQuoted(args[1], env)
  raise newSushiError(if message.kind == Text: message.textValue else: formatValue(message), target.span)

proc catchCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len < 1 or args.len > 2:
    raise newSushiError("Native command 'catch' requires 1-2 arguments.")
  let expr = args[0]
  try:
    result = evaluator.evaluateQuoted(expr, env)
  except CatchableError as err:
    if args.len == 2:
      let doBlock = requireBlock(args[1])
      var catchEnv = env.push
      catchEnv.define(newSymbol("error-message"), newText(err.msg))
      result = evaluator.evaluateBlock(doBlock, catchEnv)
    else:
      result = newNilValue()

proc coalesceCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command '??' requires exactly two arguments.")
  let leftExpr = args[0]
  let right = args[1]
  try:
    result = evaluator.evaluateQuoted(leftExpr, env)
  except CatchableError:
    if right.kind == Block:
      let rightEnv = env.push
      rightEnv.define(newSymbol("error-message"), newText(getCurrentException().msg))
      result = evaluator.evaluateBlock(right, rightEnv)
    else:
      result = evaluator.evaluateQuoted(right, env)

proc orElseQuitCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command '!!' requires exactly two arguments.")
  let leftExpr = args[0]
  let rightBlock = args[1]
  if rightBlock.kind != Block:
    raise newSushiError("Native command '!!' requires a do-block as second argument.")
  try:
    result = evaluator.evaluateQuoted(leftExpr, env)
  except CatchableError as err:
    var catchEnv = env.push
    catchEnv.define(newSymbol("error-message"), newText(err.msg))
    result = evaluator.evaluateBlock(rightBlock, catchEnv)
    quit(1)

proc runCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'run' requires exactly one argument.")
  let source = evaluator.evaluateQuoted(args[0], env)
  if source.kind != Text:
    raise newSushiError("Native command 'run' expects text.")
  evaluator.evaluateSource(source.textValue, "<input>", env)

proc runFileCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'run-file' requires exactly one argument.")
  let pathValue = evaluator.evaluateQuoted(args[0], env)
  if pathValue.kind != Text:
    raise newSushiError("Native command 'run-file' expects text.")
  env.runtimeState.loadEntryModule(pathValue.textValue, evaluator).lastResult

proc funCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  discard evaluator
  if args.len < 2 or args.len > 3 or args[0].kind != Symbol:
    raise newSushiError("Native command 'fun' expects 'fun name [params] do ... end', 'fun name args do ... end', or 'fun name do ... end'.")
  let variadic = args.len == 3 and args[1].kind == Symbol
  let parameters =
    if args.len == 2: @[]
    elif variadic: @[args[1]]
    else: readParameters(args[1])
  let body = requireBlock(args[^1])
  let function = userCommandKind(
    name: args[0].symbolValue,
    parameters: parameters,
    body: body,
    definingEnv: env,
    variadic: variadic,
    span: cover(args[0].span, body.span)
  )
  let functionValue = newUserCommandValue(function)
  env.define(args[0], functionValue)
  functionValue

proc fnCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  discard evaluator
  if args.len != 2:
    raise newSushiError("Native command 'fn' expects 'fn [params] body'.")
  let parameters = readParameters(args[0])
  let body = normalizeCallableBody(args[1])
  newUserCommandValue(userCommandKind(
    name: "<lambda>",
    parameters: parameters,
    body: body,
    definingEnv: env,
    variadic: false,
    span: cover(args[0].span, body.span)
  ))

proc classCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 3 or args[0].kind != Symbol:
    raise newSushiError("Native command 'class' expects 'class Name [Base] do ... end'.")
  let baseClass = resolveBaseClass(args[1], env)
  let body = requireBlock(args[2])
  let classDef = ClassDef(
    name: args[0].symbolValue,
    baseClass: baseClass,
    definingEnv: env,
    runtimeState: env.runtimeState,
    declaredFields: @[],
    fieldDefaults: initOrderedTable[string, Value](),
    instanceMethods: initOrderedTable[string, MethodDef](),
    classMethods: initOrderedTable[string, MethodDef](),
    span: args[0].span
  )
  for command in body.blockCommands:
    defineClassMember(classDef, command, evaluator, env)
  env.runtimeState.classes[classDef.name] = classDef
  let classValue = newClassValue(classDef)
  env.define(args[0], classValue)
  classValue

proc newCommandProc(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len == 0:
    raise newSushiError("Native command 'new' requires a class.")
  let classValue = evaluator.evaluateQuoted(args[0], env)
  if classValue.kind != Class:
    raise newSushiError("Native command 'new' expects a class as its first argument.")
  let instance = classValue.classDef.createInstance
  let initMethod = classValue.classDef.getInstanceMethod("init")
  if not initMethod.isNil:
    inc ctorCallCount
    discard invokeMethod(initMethod, evaluator, instance, args[1 .. ^1], env)
  elif args.len > 1:
    raise newSushiError("classKind " & classValue.classDef.name & " does not define init.")
  newInstanceValue(instance)

proc ctorCalledCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  discard evaluator
  discard env
  if args.len != 0:
    raise newSushiError("Native command 'ctorCalled' does not take arguments.")
  newInteger(ctorCallCount)

proc useCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len < 1 or args.len > 2 or args[0].kind != Symbol:
    raise newSushiError("Native command 'use' expects 'use module' or 'use module global'.")
  if args.len == 2 and not (args[1].kind == Symbol and args[1].symbolValue == "global"):
    raise newSushiError("Native command 'use' expects 'use module' or 'use module global'.")
  let importerPath = if env.currentModule.isNil: "" else: env.currentModule.filePath
  let moduleValue = env.runtimeState.loadModule(args[0].symbolValue, importerPath, evaluator)
  let targetScope = env.getModuleGlobalScope
  targetScope.define(args[0], moduleValue)
  if args.len == 2:
    for key, item in moduleValue.exports.pairs:
      targetScope.define(newSymbol(key), item)
  moduleValue

proc iterateCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 3:
    raise newSushiError("Native command 'iterate' expects 'iterate item iterator do ... end'.")
  let itemValue = resolveRawValue(args[0], evaluator, env)
  if itemValue.kind != Symbol:
    raise newSushiError("Native command 'iterate' expects a symbol as its first argument.")
  let iteratorValue = evaluator.evaluateQuoted(args[1], env)
  if not iteratorValue.isCallable:
    raise newSushiError("Native command 'iterate' expects an iterator callable as its second argument.")
  let bodyState = resolveRawValueWithCapture(args[2], evaluator, env)
  if bodyState.value.kind != Block:
    raise newSushiError("Native command 'iterate' expects a block as its third argument.")
  let loopEnv =
    if bodyState.hasCapturedEnv and not bodyState.env.isNil:
      bodyState.env.createReplayScope(env)
    else:
      env.push
  let doneValue = newSymbol(":done")
  var loopResult = newBoolean(false)
  while true:
    let nextValue = invokeValue(iteratorValue, evaluator, env, @[])
    if nextValue == doneValue:
      return loopResult
    loopEnv.define(itemValue, nextValue)
    loopResult = evaluator.evaluateBlock(bodyState.value, loopEnv)

proc commandCountCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'command-count' requires exactly one argument.")
  let target = resolveRawValue(args[0], evaluator, env)
  if target.kind != Block:
    raise newSushiError("Native command 'command-count' expects a block.")
  newInteger(target.blockCommands.len)

proc commandAtCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'command-at' requires exactly two arguments.")
  let target = resolveRawValueWithCapture(args[0], evaluator, env)
  if target.value.kind != Block:
    raise newSushiError("Native command 'command-at' expects a block as its first argument.")
  let idx = evaluator.evaluateQuoted(args[1], env)
  if idx.kind != Integer or idx.intValue < 0 or idx.intValue >= target.value.blockCommands.len:
    raise newSushiError("commandKind index is out of range.")
  preserveCapture(target.value.blockCommands[idx.intValue], target)

proc objectCountCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'object-count' requires exactly one argument.")
  let target = resolveRawValue(args[0], evaluator, env)
  if target.kind != Command:
    raise newSushiError("Native command 'object-count' expects a command.")
  newInteger(target.objects.len)

proc objectAtCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'object-at' requires exactly two arguments.")
  let target = resolveRawValueWithCapture(args[0], evaluator, env)
  if target.value.kind != Command:
    raise newSushiError("Native command 'object-at' expects a command as its first argument.")
  let idx = evaluator.evaluateQuoted(args[1], env)
  if idx.kind != Integer or idx.intValue < 0 or idx.intValue >= target.value.objects.len:
    raise newSushiError("objectSegment index is out of range.")
  preserveCapture(target.value.objects[idx.intValue], target)

proc countCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'count' requires exactly one argument.")
  let value = evaluateQuotedWithCapture(args[0], evaluator, env).value
  if value.kind != Sequence:
    raise newSushiError("Native command 'count' expects an iterable.")
  newInteger(value.items.len)

proc lengthCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'length' requires exactly one argument.")
  let value = evaluateQuotedWithCapture(args[0], evaluator, env).value
  case value.kind
  of Text:
    newInteger(value.textValue.len)
  of Sequence:
    newInteger(value.items.len)
  of Array:
    newInteger(value.elements.len)
  else:
    raise newSushiError("Cannot get the length of value")

proc atCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'at' requires exactly two arguments.")
  var seqState = evaluateQuotedWithCapture(args[0], evaluator, env)
  seqState.value = unwrapSequenceLike(seqState.value)
  if seqState.value.kind != Sequence:
    raise newSushiError("Native command 'at' expects a list as its first argument.")
  let idx = evaluator.evaluateQuoted(args[1], env)
  if idx.kind != Integer or idx.intValue < 0 or idx.intValue >= seqState.value.items.len:
    raise newSushiError("List index is out of range.")
  preserveCapture(seqState.value.items[idx.intValue], seqState)

proc listCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  newSequence(args.mapIt(evaluator.evaluateQuoted(it, env)))

proc tableCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len mod 2 != 0:
    raise newSushiError("Native command 'table' requires an even number of arguments.")
  var entries = initTable[Value, Value]()
  var i = 0
  while i < args.len:
    entries[evaluator.evaluateQuoted(args[i], env)] = evaluator.evaluateQuoted(args[i + 1], env)
    i += 2
  newTable(entries)

proc arrayCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len == 0:
    raise newSushiError("Native command 'array' requires at least one dimension.")
  var dimensions: seq[int]
  for arg in args:
    let dim = evaluator.evaluateQuoted(arg, env)
    if dim.kind != Integer or dim.intValue <= 0:
      raise newSushiError("arrayKind dimensions must be positive integers.")
    dimensions.add(dim.intValue)
  buildArray(dimensions, 0)

proc assertCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'assert' requires exactly one argument.")
  let condition = evaluator.evaluateQuoted(args[0], env)
  if not (condition.kind == Boolean and condition.boolValue):
    raise newSushiError("Assertion failed: " & formatValue(args[0]))
  condition

proc appendCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command 'append' requires exactly two arguments.")
  let sequenceValue = evaluator.evaluateQuoted(args[0], env)
  if sequenceValue.kind != Sequence:
    raise newSushiError("Native command 'append' expects a list as its first argument.")
  let value = evaluator.evaluateQuoted(args[1], env)
  sequenceValue.items.add(value)
  value

proc isBlockCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'is-block' requires exactly one argument.")
  newBoolean(resolveRawValue(args[0], evaluator, env).kind == Block)

proc tableValuesCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 1:
    raise newSushiError("Native command 'table-values' requires exactly one argument.")
  let tableValue = evaluator.evaluateQuoted(args[0], env)
  if tableValue.kind != Table:
    raise newSushiError("Native command 'table-values' expects a table.")
  let values = toSeq(tableValue.entries.values)
  var index = 0
  newNativeCommandValue(nativeCommandKind(name: "table-values:iterator",
    implementation: proc (ev: Evaluator; iterEnv: Env; iterArgs: seq[Value]): Value =
      discard ev
      discard iterEnv
      if iterArgs.len != 0:
        raise newSushiError("tableKind value iterators do not take arguments.")
      if index >= values.len:
        return newSymbol(":done")
      result = values[index]
      inc index
  ))

proc addCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len == 0:
    raise newSushiError("Native command '+' requires at least one argument.")
  let values = args.mapIt(evaluator.evaluateQuoted(it, env))
  if values.allIt(it.kind == Integer):
    return newInteger(values.foldl(a + b.intValue, 0))
  var total = 0.0
  for value in values:
    total += readNumericValue(value)
  newReal(total)

proc subtractCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len == 0:
    raise newSushiError("Native command '-' requires at least one argument.")
  let values = args.mapIt(evaluator.evaluateQuoted(it, env))
  if values.len == 1:
    case values[0].kind
    of Integer:
      return newInteger(-values[0].intValue)
    of Real:
      return newReal(-values[0].realValue)
    else:
      raise newSushiError("Expected numeric argument, got " & formatValue(values[0]) & ".")
  if values.allIt(it.kind == Integer):
    var total = values[0].intValue
    for value in values[1 .. ^1]:
      total -= value.intValue
    return newInteger(total)
  var total = readNumericValue(values[0])
  for value in values[1 .. ^1]:
    total -= readNumericValue(value)
  newReal(total)

proc lessThanCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command '<' requires exactly two arguments.")
  newBoolean(readNumericValue(evaluator.evaluateQuoted(args[0], env)) < readNumericValue(evaluator.evaluateQuoted(args[1], env)))

proc greaterThanCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command '>' requires exactly two arguments.")
  newBoolean(readNumericValue(evaluator.evaluateQuoted(args[0], env)) > readNumericValue(evaluator.evaluateQuoted(args[1], env)))

proc dotCommand(evaluator: Evaluator; env: Env; args: seq[Value]): Value =
  if args.len != 2:
    raise newSushiError("Native command '.' requires exactly two arguments.")
  evaluator.evaluateDotAccess(newCommand(@[newSymbol("."), args[0], args[1]]), @[], env)

proc bindNativeCommands(env: Env) =
  for (name, implementation) in [
    ("if", ifCommand),
    ("cond", condCommand),
    ("while", whileCommand),
    ("let", letCommand),
    ("var", varCommand),
    ("set", setCommand),
    ("eval", evalCommand),
    ("eval-value", evalValueCommand),
    ("raw", rawCommand),
    ("capture", captureCommand),
    ("capture-source", captureSourceCommand),
    ("replay", replayCommand),
    ("eq", eqCommand),
    ("not", notCommand),
    ("and", andCommand),
    ("or", orCommand),
    ("read-line", readLineCommand),
    ("error", errorCommand),
    ("error-at", errorAtCommand),
    ("catch", catchCommand),
    ("??", coalesceCommand),
    ("!!", orElseQuitCommand),
    ("run", runCommand),
    ("run-file", runFileCommand),
    ("fun", funCommand),
    ("fn", fnCommand),
    ("class", classCommand),
    ("new", newCommandProc),
    ("ctorCalled", ctorCalledCommand),
    ("use", useCommand),
    ("iterate", iterateCommand),
    ("command-count", commandCountCommand),
    ("command-at", commandAtCommand),
    ("object-count", objectCountCommand),
    ("object-at", objectAtCommand),
    ("count", countCommand),
    ("length", lengthCommand),
    ("at", atCommand),
    ("list", listCommand),
    ("table", tableCommand),
    ("append", appendCommand),
    ("is-block", isBlockCommand),
    ("table-values", tableValuesCommand),
    (".", dotCommand),
    ("+", addCommand),
    ("-", subtractCommand),
    ("<", lessThanCommand),
    (">", greaterThanCommand),
    ("array", arrayCommand),
    ("assert", assertCommand)
  ]:
    env.define(newSymbol(name), newNativeCommandValue(nativeCommandKind(name: name, implementation: implementation)))

type
  SushiRuntime* = ref object
    evaluator*: Evaluator
    environment*: Env
    runtimeState*: RuntimeState

proc registerNativeModule*(runtime: SushiRuntime; definition: NativeModuleDefinition): SushiRuntime =
  let moduleValue = newModuleValue(definition.name, "<native:" & definition.name & ">")
  for key, item in definition.exports.pairs:
    moduleValue.exportValue(key, item)
  runtime.runtimeState.registerNativeModule(moduleValue)
  runtime

proc bindCliArguments(runtime: SushiRuntime; args: seq[string]) =
  let values = args.mapIt(newText(it))
  runtime.environment.define(newSymbol("argc"), newInteger(args.len))
  runtime.environment.define(newSymbol("argv"), newSequence(values))

proc loadPrelude*(runtime: SushiRuntime) =
  let embeddedPrelude = findEmbeddedScript("prelude.sushi")
  if embeddedPrelude.isSome:
    let prelude = embeddedPrelude.get
    discard runtime.evaluator.evaluateSource(newSourceFile(prelude.sourceName, prelude.source), runtime.environment)
  else:
    let preludePath = resolveScriptPath("prelude.sushi")
    discard runtime.evaluator.evaluateSource(newSourceFile(preludePath, readFile(preludePath)), runtime.environment)

proc newRuntime*(args: seq[string] = @[]): SushiRuntime =
  let runtimeState = initRuntimeState()
  let environment = createRootEnv(runtimeState)
  result = SushiRuntime(evaluator: newEvaluator(), environment: environment, runtimeState: runtimeState)
  result.bindCliArguments(args)

proc evaluate*(runtime: SushiRuntime; source: string): Value =
  runtime.evaluator.evaluateSource(source, "<stdin>", runtime.environment)

proc evaluateFile*(runtime: SushiRuntime; filePath: string): Value =
  runtime.runtimeState.loadEntryModule(filePath, runtime.evaluator).lastResult

proc runFile*(runtime: SushiRuntime; filePath: string): Value =
  try:
    runtime.evaluateFile(filePath)
  except CatchableError as err:
    newText(formatDiagnostic(err, false))
