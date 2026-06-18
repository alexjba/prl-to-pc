# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# When built inside the status-desktop vendor tree, resolve the vendored deps
# (regex/unicodedb live as sibling submodules) without needing them nimble-installed
# or fetched from the network. Guarded so a standalone clone is unaffected.
when system.fileExists(thisDir() & "/../nim-regex/src/regex.nim"):
  switch("path", thisDir() & "/../nim-regex/src")
when system.fileExists(thisDir() & "/../nim-unicodedb/src/unicodedb.nim"):
  switch("path", thisDir() & "/../nim-unicodedb/src")