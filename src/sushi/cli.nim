import diagnostics
import model
import native_modules
import runtime

proc runCli*(args: seq[string]): int =
  try:
    let runtime = newRuntime(args)
      .registerNativeModule(buildIoModule())
      .registerNativeModule(buildBaseModule())
      .registerNativeModule(buildMathModule())
      .registerNativeModule(buildSyntaxModule())
    let cliPath = resolveScriptPath("cli.sushi")
    let cliResult = runtime.evaluateFile(cliPath)
    if cliResult.kind == Integer:
      cliResult.intValue
    else:
      0
  except CatchableError as err:
    stderr.writeLine(formatDiagnostic(err))
    1
