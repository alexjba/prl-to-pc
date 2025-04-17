import os, strutils, re, strformat

type
  QtModule = object
    name*: string  # Full name including version and architecture
    description*: string
    version*: string
    requires*: seq[string]
    libName*: string
    libs*: string
    cflags*: string

proc getQtVersion(prlPath: string): string =
  ## Get Qt version from the .prl file name or content
  result = "6.0.0"  # Default version if not found
  let fileName = prlPath.splitPath().tail
  let versionMatch = fileName.findAll(re"\d+\.\d+\.\d+")
  if versionMatch.len > 0:
    result = versionMatch[0]
  else:
    # Try to find version in parent directory names
    for parent in prlPath.parentDirs():
      let dirVersionMatch = parent.splitPath().tail.findAll(re"\d+\.\d+\.\d+")
      if dirVersionMatch.len > 0:
        result = dirVersionMatch[0]
        break

proc getDependencies(prlPath: string): seq[string] =
  ## Get Qt dependencies from the .prl file
  result = @[]
  if fileExists(prlPath):
    let content = readFile(prlPath)
    for line in content.splitLines():
      if line.startsWith("QMAKE_PRL_LIBS"):
        for part in line.split():
          if part.startsWith("-l"):
            let lib = part[2..^1]
            # Only add Qt libraries as dependencies, ignore system libraries
            if lib.startsWith("Qt") or lib.startsWith("qt"):
              # Remove any version suffixes and arm64-v8a suffix
              let cleanLib = lib.replace(re"_arm64-v8a$", "")
              if not result.contains(cleanLib):
                result.add(cleanLib)
          elif part.contains("libQt"):  # Handle full paths to Qt libraries
            let libName = part.splitPath().tail
              .replace(re"^lib(Qt\d*)?", "")
              .replace(".so", "")
              .replace("_arm64-v8a", "")  # Remove arm64-v8a suffix
            if not result.contains(libName):
              result.add(libName)

proc cleanLibraryName(name: string): string =
  result = name.replace("_arm64-v8a", "")

proc parsePrlFile*(filePath: string): QtModule =
  var moduleInfo = QtModule()
  var currentSection = ""
  
  for line in lines(filePath):
    if line.startsWith("QMAKE_PRL_BUILD_DIR"):
      continue
      
    if line.startsWith("QMAKE_PRL_TARGET"):
      let parts = line.split("=")
      if parts.len > 1:
        moduleInfo.libName = parts[1].strip()
        let baseName = moduleInfo.libName.replace("lib", "").replace(".so", "")
        moduleInfo.name = baseName  # Don't clean the name here, we need it for the library
        moduleInfo.description = baseName & " module"  # Remove redundant Qt prefix
        
    elif line.startsWith("QMAKE_PRL_VERSION"):
      let parts = line.split("=")
      if parts.len > 1:
        moduleInfo.version = parts[1].strip()

    elif line.startsWith("QMAKE_PRL_LIBS_FOR_CMAKE"):
      let parts = line.split("=")
      if parts.len > 1:
        let deps = parts[1].strip().split(";")
        var requires: seq[string] = @[]
        for dep in deps:
          if dep.startsWith("$$[QT_INSTALL_LIBS]/lib"):
            let depName = dep.replace("$$[QT_INSTALL_LIBS]/lib", "").split(".")[0]
            requires.add(depName)  # Keep the original dependency name
        moduleInfo.requires = requires

    elif line.startsWith("QMAKE_PRL_LIBS"):
      let parts = line.split("=")
      if parts.len > 1:
        var libs = parts[1].strip()
        # Remove $$[QT_INSTALL_LIBS] references
        libs = libs.replace(re"\$\$\[QT_INSTALL_LIBS\]/", "")
        # Replace semicolons with spaces
        libs = libs.replace(";", " ")
        libs = libs.replace("lib", "-l")
        libs = libs.replace(".so", "")
        moduleInfo.libs = "-L${libdir} -l" & moduleInfo.name & " " & libs
  let baseName = moduleInfo.name.split("_")[0].replace("6", "").replace("5", "")
  moduleInfo.cflags = "-I${includedir} -I${includedir}/" & baseName & " -DQT_" & baseName.toUpper() & "_LIB"
  return moduleInfo

proc generatePcFile(module: QtModule, outputDir: string, prefix: string, hostBins: string) =
  let host_bins = if hostBins.len > 0: hostBins else: "${prefix}" & DirSep & "bin"
  ## Generate a .pc file for a Qt module
  let content = fmt"""prefix={prefix}
exec_prefix=${{prefix}}
bindir=${{prefix}}{DirSep}bin
libexecdir=${{prefix}}{DirSep}libexec
libdir=${{prefix}}{DirSep}lib
includedir=${{prefix}}{DirSep}include
host_bins={host_bins}

Name: {module.name}
Description: {module.description}
Version: {module.version}
Libs: {module.libs}
Cflags: {module.cflags}"""
  
  let finalContent = if module.requires.len > 0:
    content & "\nRequires: " & module.requires.join(" ")
  else:
    content
  
  # Use the module name without additional Qt prefix
  let outputPath = joinPath(outputDir, module.name & ".pc")
  echo "Writing to: ", outputPath
  writeFile(outputPath, finalContent & "\n")

proc processDirectory(dir: string, outputDir: string, prefix: string, hostBins: string) =
  ## Recursively process a directory for .prl files
  echo "Processing directory: ", dir
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".prl"):
      echo "Found .prl file: ", path
      let module = parsePrlFile(path)
      generatePcFile(module, outputDir, prefix, hostBins)
    elif kind == pcDir:
      processDirectory(path, outputDir, prefix, hostBins)

proc convertPrlToPc*(inputDir, outputDir, prefix, hostBins: string) =
  ## Convert Qt .prl files to pkg-config files
  ## inputDir: Directory containing .prl files
  ## outputDir: Directory where .pc files will be generated
  ## prefix: Installation prefix path for the libraries
  createDir(outputDir)
  echo "Scanning directory: ", inputDir
  processDirectory(inputDir, outputDir, prefix, hostBins)

when isMainModule:
  if paramCount() < 3:
    echo "Usage: prl_to_pc <input_dir> <output_dir> <prefix>"
    echo "   or: prl_to_pc convert <input_dir> <output_dir> <prefix>"
    quit(1)
  echo "paramCount: ", paramCount()
  var inputDir, outputDir, prefix, hostBins: string
  
  if paramStr(1) == "convert":
    if paramCount() < 4:
      echo "Usage: prl_to_pc convert <input_dir> <output_dir> <prefix>"
      quit(1)
    inputDir = paramStr(2)
    outputDir = paramStr(3)
    prefix = paramStr(4)
    if paramCount() > 4:
      hostBins = paramStr(5)
  else:
    inputDir = paramStr(1)
    outputDir = paramStr(2)
    prefix = paramStr(3)
    if paramCount() > 3:
      hostBins = paramStr(4)

  echo "inputDir: ", inputDir
  echo "outputDir: ", outputDir
  echo "prefix: ", prefix
  echo "hostBins: ", hostBins
  
  convertPrlToPc(inputDir, outputDir, prefix, hostBins) 