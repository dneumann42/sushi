import std/os
import sushi/[diagnostics, embed, model, native_modules, runtime]

export diagnostics, embed, model, native_modules, runtime

type
  SushiRuntimeHandle = object
    runtime: SushiRuntime

proc handleFromPointer(handle: pointer): ptr SushiRuntimeHandle =
  if handle.isNil:
    raise newException(ValueError, "runtime handle is nil")
  cast[ptr SushiRuntimeHandle](handle)

proc copyToCString(value: string): cstring =
  let size = value.len + 1
  let buffer = cast[ptr UncheckedArray[char]](alloc(size))
  if value.len > 0:
    copyMem(addr buffer[0], unsafeAddr value[0], value.len)
  buffer[value.len] = '\0'
  cast[cstring](buffer)

proc writeStatus(status: ptr cint; value: cint) =
  if not status.isNil:
    status[] = value

proc renderResult(body: proc (): Value; status: ptr cint): cstring =
  try:
    status.writeStatus(0)
    copyToCString(formatValue(body()))
  except CatchableError as err:
    status.writeStatus(1)
    copyToCString(formatDiagnostic(err, false))

proc sushi_runtime_new*(): pointer {.cdecl, exportc, dynlib.} =
  let handle = create(SushiRuntimeHandle)
  handle.runtime = newEmbeddedRuntime()
  cast[pointer](handle)

proc sushi_runtime_new_with_args*(argc: cint; argv: cstringArray): pointer {.cdecl, exportc, dynlib.} =
  var args: seq[string]
  if argc > 0 and not argv.isNil:
    for index in 0 ..< int(argc):
      args.add($argv[index])
  let handle = create(SushiRuntimeHandle)
  handle.runtime = newEmbeddedRuntime(args)
  cast[pointer](handle)

proc sushi_runtime_free*(handle: pointer) {.cdecl, exportc, dynlib.} =
  if handle.isNil:
    return
  let runtimeHandle = cast[ptr SushiRuntimeHandle](handle)
  reset(runtimeHandle.runtime)
  dealloc(runtimeHandle)

proc sushi_string_free*(value: cstring) {.cdecl, exportc, dynlib.} =
  if not value.isNil:
    dealloc(cast[pointer](value))

proc sushi_runtime_eval*(handle: pointer; source: cstring; status: ptr cint): cstring {.cdecl, exportc, dynlib.} =
  let runtimeHandle = handleFromPointer(handle)
  renderResult(proc (): Value = runtimeHandle.runtime.evaluate($source), status)

proc sushi_runtime_eval_file*(handle: pointer; filePath: cstring; status: ptr cint): cstring {.cdecl, exportc, dynlib.} =
  let runtimeHandle = handleFromPointer(handle)
  renderResult(proc (): Value = runtimeHandle.runtime.evaluateFile($filePath), status)

proc sushi_runtime_run_file*(handle: pointer; filePath: cstring; status: ptr cint): cstring {.cdecl, exportc, dynlib.} =
  let runtimeHandle = handleFromPointer(handle)
  renderResult(proc (): Value =
    let resolvedPath = absolutePath($filePath)
    runtimeHandle.runtime.runFile(resolvedPath),
    status)
