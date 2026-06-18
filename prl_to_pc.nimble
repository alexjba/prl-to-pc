# Package
version       = "0.1.0"
author        = "AlexJb"
description   = "Convert Qt .prl files to pkg-config .pc files"
license       = "MIT"
srcDir        = "src"
bin           = @["prl_to_pc"]

# Dependencies
requires "nim >= 1.6.0"
requires "regex"

# Build the unified pkg-config wrapper -> `pkg-config` (`pkg-config.exe` on
# Windows), so it can shadow the real tool on PATH. The wrapper is dependency-free
# (no `regex`), so this compiles cleanly with plain `nim c`. Invoked as
# `nimble build` (nimbus-build-system's nimble runs .nimble TASKS via nim).
task build, "Build the unified pkg-config wrapper (pkg-config[.exe])":
  exec "nim c -d:release --hints:off --skipParentCfg:on -o:pkg-config src/pkgconfig_wrapper.nim"

# Tasks
task convert, "Convert .prl files to .pc files in a directory":
  echo "Converting .prl files to .pc files"
  for i in 1..paramCount():
    echo "Param " & $i & ": " & paramStr(i)
    if paramStr(i) == "convert":
      let inputDir = paramStr(i+1)
      let outputDir = paramStr(i+2)
      let prefix = paramStr(i+3)
      let hostBins = if i+4 <= paramCount(): paramStr(i+4) else: ""
      exec "nim c -r src/prl_to_pc.nim " & inputDir & " " & outputDir & " " & prefix & " " & hostBins
      break