# Package
version       = "0.1.0"
author        = "Your Name"
description   = "Convert Qt .prl files to pkg-config .pc files"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.6.0"

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