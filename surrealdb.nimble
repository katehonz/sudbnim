# Package
version       = "0.3.0"
author        = "sudbnim contributors"
description   = "Production-grade SurrealDB driver for Nim (SurrealDB 2.x/3.x)"
license       = "MIT"
srcDir        = "src"
installDirs   = @["src/surrealdb"]

# Dependencies
requires "nim >= 2.0.0"

# Tasks
task test, "Run all tests":
  for file in [
    "test_unit.nim",
    "test_mock.nim",
    "test_typed.nim",
    "test_integration.nim",
    "test_reconnect.nim",
  ]:
    echo "Running ", file, " ..."
    exec "nim c -r --hints:off --path:src tests/" & file
