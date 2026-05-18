import diagnostics
import nativeModules
import runtime

proc newEmbeddedRuntime*(args: seq[string] = @[]): SushiRuntime =
  result = newRuntime(args)
  discard result
    .registerNativeModule(buildIoModule())
    .registerNativeModule(buildHttpModule())
    .registerNativeModule(buildBaseModule())
    .registerNativeModule(buildMathModule())
    .registerNativeModule(buildSyntaxModule())
    .registerNativeModule(buildDocsModule())
  result.loadPrelude()

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
