import std/options
import builtin_scripts
import diagnostics
import embed
import model
import runtime

proc runCli*(args: seq[string]): int =
  try:
    let runtime = newEmbeddedRuntime(args)
    let embeddedCli = findEmbeddedScript("cli.sushi")
    let cliResult =
      if embeddedCli.isSome:
        let script = embeddedCli.get
        runtime.evaluator.evaluateSource(newSourceFile(script.sourceName, script.source), runtime.environment)
      else:
        let cliPath = resolveScriptPath("cli.sushi")
        runtime.evaluateFile(cliPath)
    if cliResult.kind == Integer:
      cliResult.intValue
    else:
      0
  except CatchableError as err:
    stderr.writeLine(formatDiagnostic(err))
    1
