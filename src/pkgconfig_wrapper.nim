# Unified pkg-config wrapper (all platforms) — built from prl-to-pc, delivered as
# `pkg-config` / `pkg-config.exe` and placed first on PATH.
#
# Purpose: seaqt locates Qt at nim-compile time via gorge("pkg-config ...") and the
# build's Makefile also calls pkg-config. The committed prl-to-pc .pc files are
# relocatable (${prefix}-relative) but DON'T live in the Qt kit, so the real prefix
# must be supplied explicitly. This wrapper, for packages matching a configured
# pattern, prepends `--define-variable=prefix=<prefix>` (which overrides ${prefix}
# for the whole query regardless of the .pc file's on-disk location), then delegates
# to the real pkg-config/pkgconf. For non-matching packages it is a transparent
# pass-through.
#
# Configuration (env var PKG_CONFIG_PREFIX_OVERRIDE): a comma-separated list of
# `pattern=prefix` entries, optional surrounding [ ]. `*` is a glob wildcard.
#   e.g.  PKG_CONFIG_PREFIX_OVERRIDE='Qt*=C:/Qt/6.11.0/msvc2022_64'
#
# It also strips trailing whitespace from pkg-config's output (nim's gorge keeps the
# LF of a CRLF, which breaks parseInt(QtCoreBuildVersion) in seaqt).
#
# CRITICAL — never recurse into ourselves (a self-call fork-bombs the machine). Three
# guards: (1) exclude our own dir/file from the real-tool search by OS file-identity
# (sameFile — immune to slash/case/8.3/MSYS-form differences that string compares
# miss); (2) refuse to exec a "real" tool that is the same file as ourselves;
# (3) a re-entrancy env flag so a wrapper invoked by another wrapper bails at once.

import std/[os, strutils]

const
  OverrideEnv* = "PKG_CONFIG_PREFIX_OVERRIDE"
  ArchEnv* = "PKG_CONFIG_ARCH"
  ReentryFlag = "STATUS_PKGCONFIG_WRAP_ACTIVE"

# ---------------------------------------------------------------------------
# Pure, testable logic
# ---------------------------------------------------------------------------

proc globMatch*(name, pattern: string): bool =
  ## Minimal glob: `*` matches any run (incl. empty); every other char is literal.
  ## No `?`/character classes (not needed for package-name patterns like "Qt*").
  var
    n = 0            # index into name
    p = 0            # index into pattern
    star = -1        # last '*' position in pattern
    mark = 0         # name index to backtrack to
  while n < name.len:
    if p < pattern.len and (pattern[p] == name[n]):
      inc n; inc p
    elif p < pattern.len and pattern[p] == '*':
      star = p; mark = n; inc p
    elif star != -1:
      p = star + 1; inc mark; n = mark
    else:
      return false
  while p < pattern.len and pattern[p] == '*':
    inc p
  result = p == pattern.len

proc parseOverrides*(s: string): seq[tuple[pattern, prefix: string]] =
  ## Parse "Qt*=/qt,Foo*=/foo" (optionally wrapped in [ ]) into (pattern, prefix).
  ## Splits entries on ',' and each entry on its FIRST '='. Blank/'='-less entries
  ## are skipped. (Prefixes are paths; they contain no ',' in practice.)
  var body = s.strip()
  if body.startsWith("[") and body.endsWith("]"):
    body = body[1 ..< body.len - 1]
  for raw in body.split(','):
    let entry = raw.strip()
    if entry.len == 0: continue
    let eq = entry.find('=')
    if eq <= 0: continue
    let pat = entry[0 ..< eq].strip()
    let prefix = entry[eq + 1 .. ^1].strip()
    if pat.len == 0 or prefix.len == 0: continue
    result.add (pattern: pat, prefix: prefix)

proc isPackageArg(a: string): bool =
  ## A pkg-config package name (not a flag). Flags start with '-'.
  a.len > 0 and not a.startsWith("-")

proc isQtPackage(a: string): bool =
  ## A versioned Qt package name, e.g. Qt6Core (Qt followed by a version digit).
  a.len >= 3 and a[0] == 'Q' and a[1] == 't' and a[2] in {'0'..'9'}

proc applyArchSuffix*(args: seq[string], arch: string): seq[string] =
  ## Android single-arch kits name libs/.pc with an ABI suffix
  ## (libQt6Core_arm64-v8a.so -> Qt6Core_arm64-v8a.pc), but seaqt's gorge queries the
  ## bare module (Qt6Core). When PKG_CONFIG_ARCH is set, append `_<arch>` to versioned
  ## Qt package args that aren't already suffixed; flags and already-suffixed names are
  ## left untouched. Unset (desktop) -> args returned unchanged.
  if arch.len == 0:
    return args
  for a in args:
    if isPackageArg(a) and isQtPackage(a) and not a.endsWith("_" & arch):
      result.add a & "_" & arch
    else:
      result.add a

proc matchedPrefixes*(args: seq[string],
                      overrides: seq[tuple[pattern, prefix: string]]): seq[string] =
  ## Distinct prefixes (in first-seen order) for package-name args matching any
  ## override pattern. Empty when nothing matches.
  for a in args:
    if not isPackageArg(a): continue
    for ov in overrides:
      if globMatch(a, ov.pattern):
        if ov.prefix notin result:
          result.add ov.prefix
        break

proc computeExtraArgs*(args: seq[string],
                       overrides: seq[tuple[pattern, prefix: string]]): seq[string] =
  ## Args to prepend to the real pkg-config call. At most one
  ## `--define-variable=prefix=<prefix>` (pkg-config has a single `prefix` var).
  let prefixes = matchedPrefixes(args, overrides)
  if prefixes.len == 0:
    return @[]
  @["--define-variable=prefix=" & prefixes[0]]

# ---------------------------------------------------------------------------
# Real-tool discovery (recursion-safe)
# ---------------------------------------------------------------------------

proc sameFileSafe(a, b: string): bool =
  try: result = fileExists(a) and fileExists(b) and sameFile(a, b)
  except CatchableError: result = false

proc sameDirSafe(a, b: string): bool =
  try: result = dirExists(a) and dirExists(b) and sameFile(a, b)
  except CatchableError: result = false

proc findRealTool*(selfExe, selfDir: string): string =
  ## First pkgconf/pkg-config on PATH that is NOT in our own dir and NOT this very
  ## executable. sameFile() (OS identity) is used instead of string compares so we
  ## never resolve back to ourselves regardless of path form.
  for base in ["pkgconf", "pkg-config"]:
    for d in getEnv("PATH").split(PathSep):
      if d.len == 0: continue
      if sameDirSafe(d, selfDir): continue
      for cand in [d / (base & ".exe"), d / base]:
        if not fileExists(cand): continue
        if sameFileSafe(cand, selfExe): continue
        return cand
  return ""

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

when isMainModule:
  import std/[osproc, streams]

  proc main() =
    let selfExe = getAppFilename()
    let selfDir = getAppDir()

    if getEnv(ReentryFlag).len > 0:
      stderr.writeLine "pkg-config wrapper: re-entrant invocation detected, refusing (would recurse)"
      quit(127)
    putEnv(ReentryFlag, "1")

    let real = findRealTool(selfExe, selfDir)
    if real.len == 0 or sameFileSafe(real, selfExe):
      stderr.writeLine "pkg-config wrapper: no real pkg-config/pkgconf found on PATH (only ourselves)"
      quit(127)

    let cliArgs = applyArchSuffix(commandLineParams(), getEnv(ArchEnv))
    let overrides = parseOverrides(getEnv(OverrideEnv))
    if matchedPrefixes(cliArgs, overrides).len > 1:
      stderr.writeLine "pkg-config wrapper: warning: query matches multiple prefix overrides; using the first"
    let args = computeExtraArgs(cliArgs, overrides) & cliArgs

    let p = startProcess(real, args = args, options = {poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()

    # gorge keeps the LF of a CRLF; strip trailing whitespace for a clean value.
    stdout.write output.strip(leading = false, trailing = true)
    quit(code)

  main()
