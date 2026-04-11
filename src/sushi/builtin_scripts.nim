import std/[algorithm, options, os, strutils]

type
  EmbeddedScript* = object
    sourceName*: string
    source*: string

  EmbeddedScriptEntry = object
    fileName: string
    sourceName: string
    source: string

const
  scriptsDirectory = currentSourcePath.parentDir.parentDir.parentDir / "scripts"
  embeddedScriptEntries = static:
    var entries: seq[EmbeddedScriptEntry]
    for kind, path in walkDir(scriptsDirectory):
      if kind != pcFile or not path.endsWith(".sushi"):
        continue
      let fileName = path.extractFilename
      entries.add(EmbeddedScriptEntry(
        fileName: fileName,
        sourceName: "<builtin:" & fileName & ">",
        source: staticRead(path)
      ))
    entries.sort(proc (a, b: EmbeddedScriptEntry): int = cmp(a.fileName, b.fileName))
    entries

proc findEmbeddedScript*(fileName: string): Option[EmbeddedScript] =
  for entry in embeddedScriptEntries:
    if entry.fileName == fileName:
      return some(EmbeddedScript(sourceName: entry.sourceName, source: entry.source))
  none(EmbeddedScript)

proc findEmbeddedModule*(moduleName: string): Option[EmbeddedScript] =
  let fileName =
    if moduleName.endsWith(".sushi"):
      moduleName
    else:
      moduleName & ".sushi"
  findEmbeddedScript(fileName)
