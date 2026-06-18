import std/[unittest, os, osproc, strutils]
import pkgconfig_wrapper

suite "globMatch":
  test "literal":
    check globMatch("Qt6Core", "Qt6Core")
    check not globMatch("Qt6Core", "Qt6Qml")
  test "trailing star":
    check globMatch("Qt6Core", "Qt*")
    check globMatch("Qt", "Qt*")        # * matches empty
    check not globMatch("zlib", "Qt*")
  test "leading / middle star":
    check globMatch("libQt6Core", "*Core")
    check globMatch("Qt6Core", "Qt*Core")
    check not globMatch("Qt6Gui", "Qt*Core")
  test "bare star matches anything":
    check globMatch("anything", "*")

suite "parseOverrides":
  test "single":
    let ov = parseOverrides("Qt*=C:/Qt/6.11.0/msvc2022_64")
    check ov.len == 1
    check ov[0].pattern == "Qt*"
    check ov[0].prefix == "C:/Qt/6.11.0/msvc2022_64"
  test "multiple + brackets + spaces":
    let ov = parseOverrides("[Qt*=/qt, Foo*=/foo]")
    check ov.len == 2
    check ov[0] == (pattern: "Qt*", prefix: "/qt")
    check ov[1] == (pattern: "Foo*", prefix: "/foo")
  test "prefix may contain '=' after the first":
    let ov = parseOverrides("Qt*=/a=b")
    check ov.len == 1
    check ov[0].prefix == "/a=b"
  test "empty / malformed skipped":
    check parseOverrides("").len == 0
    check parseOverrides(",  ,=,foo").len == 0

suite "computeExtraArgs":
  let qt = parseOverrides("Qt*=/qt")
  test "matching package injects prefix":
    check computeExtraArgs(@["--cflags", "Qt6Core"], qt) ==
      @["--define-variable=prefix=/qt"]
  test "version-constraint args ignored, package still matched":
    check computeExtraArgs(@["--libs", "Qt6Core", ">=", "6.0"], qt) ==
      @["--define-variable=prefix=/qt"]
  test "non-matching package passes through untouched":
    check computeExtraArgs(@["--cflags", "zlib"], qt).len == 0
  test "no overrides -> no injection":
    check computeExtraArgs(@["--cflags", "Qt6Core"], @[]).len == 0
  test "flags are never treated as packages":
    check computeExtraArgs(@["--variable=prefix"], qt).len == 0

suite "applyArchSuffix":
  test "appends ABI to versioned Qt packages":
    check applyArchSuffix(@["--cflags", "Qt6Core"], "arm64-v8a") ==
      @["--cflags", "Qt6Core_arm64-v8a"]
  test "leaves flags and already-suffixed names untouched":
    check applyArchSuffix(@["--libs", "Qt6Core_arm64-v8a"], "arm64-v8a") ==
      @["--libs", "Qt6Core_arm64-v8a"]
  test "non-Qt and non-versioned packages untouched":
    check applyArchSuffix(@["zlib", "QtFoo"], "x86_64") == @["zlib", "QtFoo"]
  test "empty arch -> unchanged":
    check applyArchSuffix(@["--cflags", "Qt6Core"], "") == @["--cflags", "Qt6Core"]

suite "findRealTool excludes self (integration)":
  # Build a stub `pkg-config` that echoes its argv, plus a COPY of our wrapper next
  # to it, and confirm the wrapper resolves the stub — never the sibling copy.
  let tmp = getTempDir() / "pcwrap_test"
  removeDir(tmp)
  createDir(tmp)
  let exe = when defined(windows): ".exe" else: ""

  # stub real tool
  let stubSrc = tmp / "stub.nim"
  writeFile(stubSrc, """
import std/[os, strutils]
stdout.write commandLineParams().join("|")
""")
  let stubExe = tmp / "pkg-config" & exe
  let (_, scode) = execCmdEx("nim c --hints:off --skipParentCfg:on -o:" & quoteShell(stubExe) & " " & quoteShell(stubSrc))
  require scode == 0
  require fileExists(stubExe)

  # our wrapper, built into a DIFFERENT dir that is placed FIRST on PATH
  let wrapDir = tmp / "wrap"
  createDir(wrapDir)
  let wrapExe = wrapDir / "pkg-config" & exe
  let here = currentSourcePath().parentDir()
  let wrapSrc = here.parentDir() / "src" / "pkgconfig_wrapper.nim"
  let (_, wcode) = execCmdEx("nim c --hints:off --skipParentCfg:on -o:" & quoteShell(wrapExe) & " " & quoteShell(wrapSrc))
  require wcode == 0

  test "wrapper runs the stub (not itself) and injects the override":
    putEnv("PATH", wrapDir & $PathSep & tmp)
    putEnv(OverrideEnv, "Qt*=/qtprefix")
    delEnv("STATUS_PKGCONFIG_WRAP_ACTIVE")
    let (outp, code) = execCmdEx(quoteShell(wrapExe) & " --cflags Qt6Core")
    check code == 0
    # stub echoes argv joined by '|'; the wrapper must have prepended the override.
    check outp.strip() == "--define-variable=prefix=/qtprefix|--cflags|Qt6Core"

  test "non-matching package: no injection":
    putEnv(OverrideEnv, "Qt*=/qtprefix")
    delEnv("STATUS_PKGCONFIG_WRAP_ACTIVE")
    let (outp, code) = execCmdEx(quoteShell(wrapExe) & " --cflags zlib")
    check code == 0
    check outp.strip() == "--cflags|zlib"

  test "re-entrancy guard refuses":
    putEnv("STATUS_PKGCONFIG_WRAP_ACTIVE", "1")
    let (_, code) = execCmdEx(quoteShell(wrapExe) & " --modversion Qt6Core")
    delEnv("STATUS_PKGCONFIG_WRAP_ACTIVE")
    check code == 127
