import diagnostics
import native_modules
import runtime

proc newEmbeddedRuntime*(args: seq[string] = @[]): SushiRuntime =
  newRuntime(args)
    .registerNativeModule(buildIoModule())
    .registerNativeModule(buildBaseModule())
    .registerNativeModule(buildMathModule())
    .registerNativeModule(buildSyntaxModule())

proc evaluateToString*(runtime: SushiRuntime; source: string): string =
  try:
    formatValue(runtime.evaluate(source))
  except CatchableError as err:
    formatDiagnostic(err, false)

proc evaluateFileToString*(runtime: SushiRuntime; filePath: string): string =
  try:
    formatValue(runtime.evaluateFile(filePath))
  except CatchableError as err:
    formatDiagnostic(err, false)
