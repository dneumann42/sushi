# Package

version       = "0.0.0"
author        = "dneumann42"
description   = "A scripting language"
license       = "MIT"
srcDir        = "src"
bin           = @["sushi"]


# Dependencies

requires "nim >= 2.2.8"

task test, "Run the Sushi test suite":
  mkDir("build")
  mkDir("build/nimcache")
  exec "nim c --nimcache:build/nimcache/tests -r tests/test_runtime.nim"

when defined(windows):
  const sharedLibraryName = "sushi.dll"
elif defined(macosx):
  const sharedLibraryName = "libsushi.dylib"
else:
  const sharedLibraryName = "libsushi.so"

task buildlib, "Build the shared Sushi runtime library":
  mkDir("build")
  mkDir("build/nimcache")
  exec "nim c --nimcache:build/nimcache/lib --app:lib -o:build/" & sharedLibraryName & " src/sushilib.nim"
