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
  exec "nim c -r tests/test_runtime.nim"
