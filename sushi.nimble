# Package

version       = "0.0.0"
author        = "dneumann42"
description   = "A scripting language"
license       = "MIT"
srcDir        = "src"
bin           = @["sushi"]


# Dependencies

requires "nim >= 2.2.8"

when defined(windows):
  const binaryName = "sushi.exe"
else:
  const binaryName = "sushi"

proc ensureBuildDirs() =
  mkDir("build")
  mkDir("build/nimcache")

task test, "Run the Sushi test suite":
  ensureBuildDirs()
  exec "nim c --nimcache:build/nimcache/tests -r tests/test_runtime.nim"

when defined(windows):
  const sharedLibraryName = "sushi.dll"
elif defined(macosx):
  const sharedLibraryName = "libsushi.dylib"
else:
  const sharedLibraryName = "libsushi.so"

task buildbin, "Build the Sushi CLI binary":
  ensureBuildDirs()
  exec "nim c --nimcache:build/nimcache/bin -o:build/" & binaryName & " src/sushi.nim"

task buildlib, "Build the shared Sushi runtime library":
  ensureBuildDirs()
  exec "nim c --nimcache:build/nimcache/lib --app:lib -o:build/" & sharedLibraryName & " src/sushilib.nim"
