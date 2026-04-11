import diagnostics
import embed
import model

proc runCli*(args: seq[string]): int =
  try:
    let runtime = newEmbeddedRuntime(args)
    let cliPath = resolveScriptPath("cli.sushi")
    let cliResult = runtime.evaluateFile(cliPath)
    if cliResult.kind == Integer:
      cliResult.intValue
    else:
      0
  except CatchableError as err:
    stderr.writeLine(formatDiagnostic(err))
    1
