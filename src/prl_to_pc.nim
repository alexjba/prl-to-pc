import os, strutils, regex, strformat

proc findAllStr(s: string, pattern: Regex2): seq[string] =
  for m in findAll(s, pattern):
    result.add s[m.boundaries]

type
  QtModule = object
    name*: string  # Full name including version and architecture
    description*: string
    version*: string
    requires*: seq[string]
    libName*: string
    libs*: string
    cflags*: string
    isStatic*: bool # Flag to indicate if the library is static
    isIOS*: bool    # Flag to indicate if the library is for iOS
    libPath*: string # Full path to the library file

proc getQtVersion(prlPath: string): string =
  ## Get Qt version from the .prl file name or content
  result = "6.0.0"  # Default version if not found
  let fileName = prlPath.splitPath().tail
  let versionMatch = findAllStr(fileName, re2"\d+\.\d+\.\d+")
  if versionMatch.len > 0:
    result = versionMatch[0]
  else:
    # Try to find version in parent directory names
    for parent in prlPath.parentDirs():
      let dirVersionMatch = findAllStr(parent.splitPath().tail, re2"\d+\.\d+\.\d+")
      if dirVersionMatch.len > 0:
        result = dirVersionMatch[0]
        break

proc isStaticLibrary(content: string): bool =
  ## Check if the .prl file represents a static library
  for line in content.splitLines():
    if line.startsWith("QMAKE_PRL_CONFIG") and (line.contains("static") or line.contains("staticlib")):
      return true
  return false

proc isIOSLibrary(filePath: string): bool =
  ## Check if the library is for iOS platform
  return filePath.contains("/ios/") or filePath.contains("_ios")

proc parseFrameworkName(filePath: string): string =
  ## Extract framework name from path for iOS libraries
  let parts = filePath.split("/")
  for i in 0..<parts.len:
    if parts[i].endsWith(".framework") and i > 0:
      return parts[i].split(".")[0]
  return ""

proc cleanFrameworkReferences(libs: string): string =
  ## Clean framework references like -framework $1
  result = libs
  # Replace framework references like "-framework $1" with proper framework names
  result = result.replace(re2"-framework\s+\$\d+", "")
  # Remove any remaining framework references with no valid name
  result = result.replace(re2"-framework\s+\$\[\w+\]", "")
  # Clean up any duplicate spaces
  result = result.replace(re2"\s+", " ").strip()
  return result

proc cleanInstallPathReferences(libs: string): string =
  ## Replace Qt install path references
  result = libs
  # Replace QT_INSTALL_LIBS references
  # Plain (literal) string replaces: the patterns are literal, and the ${...}
  # replacements must NOT go through nim-regex (it treats $ as a capture ref).
  result = result.replace("$$[QT_INSTALL_LIBS]", "${libdir}")
  result = result.replace("$$[QT_INSTALL_PREFIX]", "${prefix}")
  # Replace QT_INSTALL_PLUGINS references
  result = result.replace("$$[QT_INSTALL_PLUGINS]", "${prefix}/plugins")
  # Replace QT_INSTALL_QML references
  result = result.replace("$$[QT_INSTALL_QML]", "${prefix}/qml")
  return result

proc isBundledLibrary(libName: string): bool =
  ## Check if a library is a bundled library
  return libName.contains("Bundled") or libName.startsWith("Qt6Bundled")

proc extractBundledLibrary(part: string): string =
  ## Extract bundled library name from a library reference
  # Examples: libQt6BundledPcre2.a -> Qt6BundledPcre2
  let fileName = part.splitPath().tail
  if fileName.startsWith("lib") and fileName.endsWith(".a"):
    result = fileName.replace("lib", "").replace(".a", "")
  else:
    result = fileName.replace(".a", "")
  return result

proc getLibraryDir(prlFilePath: string): string =
  ## Get the directory where the library is actually located
  var dirPath = prlFilePath.splitPath().head
  # Handle framework directory structure (the .prl is typically in Resources)
  if dirPath.contains("/Resources"):
    dirPath = dirPath.splitPath().head  # Go up one level to the framework directory
  return dirPath

proc processFullPaths(libs: string, prefix: string): string =
  ## Process full paths to libraries to use -L/-l combination
  var result = libs
  let matches = findAllStr(libs, re2"\$\{libdir\}/lib[^/\s]+\.a")
  for match in matches:
    let libName = match.splitPath().tail.replace("lib", "").replace(".a", "")
    result = result.replace(match, "-l" & libName)
  
  return result

proc getDependencies(prlPath: string, content: string): seq[string] =
  ## Get Qt dependencies from the .prl file
  result = @[]
  
  for line in content.splitLines():
    if line.startsWith("QMAKE_PRL_LIBS_FOR_CMAKE"):
      let parts = line.split("=")
      if parts.len > 1:
        let depsStr = parts[1].strip()
        for part in depsStr.split(";"):
          # Check for Qt library dependencies in different formats
          if part.contains("Qt") or part.contains("qt"):
            var libName = ""
            
            # Handle frameworks
            if part.contains(".framework"):
              for fwPart in part.split("/"):
                if fwPart.contains(".framework"):
                  libName = fwPart.split(".")[0]
                  break
            # Handle bundled static libraries
            elif part.contains("libQt") and part.contains(".a"):
              libName = extractBundledLibrary(part)
            # Handle dynamic libraries. Produce the canonical package name that
            # matches the generated .pc filename (moduleInfo.name), i.e. strip
            # only the leading "lib" and the library extension while KEEPING the
            # Qt version and any arch suffix: libQt6Core_arm64-v8a.so ->
            # Qt6Core_arm64-v8a. (The previous "^lib(Qt\d*)? -> Qt" dropped the
            # version and never stripped ".so", yielding unresolvable
            # "QtCore_arm64-v8a.so" Requires entries.)
            elif part.contains("libQt"):
              let fileName = part.splitPath().tail
              libName = fileName.replace(re2"^lib", "")
                         .replace(re2"\.(a|so|dylib)(\.\d+)*$", "")
                         .replace("_debug", "")
            
            if libName.len > 0 and not result.contains(libName) and
               (libName.startsWith("Qt") or libName.startsWith("qt")):
              # Skip bundled libraries from Requires (they should only be in Libs)
              if not isBundledLibrary(libName):
                # Check if it's already added
                var alreadyAdded = false
                for dep in result:
                  if dep.toLower() == libName.toLower():
                    alreadyAdded = true
                    break
                
                if not alreadyAdded:
                  result.add(libName)

proc cleanLibraryName(name: string): string =
  # Strip Android ABI suffixes (one of these is present per single-arch kit),
  # the debug marker, and any framework extension, leaving the canonical Qt
  # module name (e.g. Qt6Core_arm64-v8a -> Qt6Core).
  result = name.replace("_arm64-v8a", "")
            .replace("_armeabi-v7a", "")
            .replace("_x86_64", "")
            .replace("_x86", "")
            .replace("_debug", "")
            .replace(".framework", "")

proc getDependenciesFromCMake(cmakePath: string): seq[string] =
  ## Extract dependencies from CMake files
  result = @[]
  
  # Get the base module name from the path
  let fileName = cmakePath.splitPath().tail
  let moduleNameParts = fileName.split("Dependencies.cmake")
  if moduleNameParts.len < 1:
    return result
    
  let moduleNameWithQt6 = moduleNameParts[0]
  
  # Default dependencies based on module type
  if moduleNameWithQt6.contains("Quick"):
    result.add("Qt6Qml")
    result.add("Qt6OpenGL")
    result.add("Qt6Gui")
    result.add("Qt6Network")
    result.add("Qt6Core")
  elif moduleNameWithQt6.contains("Qml"):
    result.add("Qt6Network")
    result.add("Qt6Core")
  elif moduleNameWithQt6.contains("Gui"):
    result.add("Qt6Core")
  elif moduleNameWithQt6.contains("Widgets"):
    result.add("Qt6Gui")
    result.add("Qt6Core")
  elif moduleNameWithQt6.contains("Network"):
    result.add("Qt6Core")
  elif moduleNameWithQt6.contains("WebView"):
    result.add("Qt6Core")
    result.add("Qt6Gui")
    result.add("Qt6Quick")
  elif moduleNameWithQt6.contains("Core"):
    # No dependencies for Core
    discard
  else:
    # Add at least Core for any other module
    result.add("Qt6Core")
  
  return result

proc getFrameworkLibsString(module: QtModule): string =
  ## Generate framework Libs string including all dependencies
  var result = "-F${libdir} -framework " & module.libName
  
  # Add all required framework dependencies to the libs field
  for req in module.requires:
    if req.startsWith("Qt6") and req != "Qt6":
      # Convert Qt6ModuleName to the actual framework name (QtModuleName)
      let frameworkName = req.replace("Qt6", "Qt")
      result &= " -framework " & frameworkName
  
  return result

proc parseFramework*(frameworkPath: string): QtModule =
  ## Parse a Qt framework and extract module information
  var moduleInfo = QtModule()
  
  # Extract framework name from path
  let frameworkName = parseFrameworkName(frameworkPath)
  if frameworkName.len == 0:
    return moduleInfo
  
  # Store the framework path
  moduleInfo.libPath = frameworkPath
  
  # Set up the module info
  moduleInfo.isStatic = true  # iOS frameworks are static
  moduleInfo.isIOS = isIOSLibrary(frameworkPath)
  
  # Determine module name with proper Qt6 prefix
  if frameworkName.startsWith("Qt") and not frameworkName.startsWith("Qt6"):
    moduleInfo.name = "Qt6" & frameworkName.substr(2)
  else:
    moduleInfo.name = frameworkName
    
  moduleInfo.libName = frameworkName
  moduleInfo.description = moduleInfo.name & " module"
  
  # Try to extract version from the Qt installation path
  var version = "6.0.0"  # Default version
  for parent in frameworkPath.parentDirs():
    let versionMatch = findAllStr(parent.splitPath().tail, re2"\d+\.\d+\.\d+")
    if versionMatch.len > 0:
      version = versionMatch[0]
      break
  moduleInfo.version = version
  
  # Look for dependencies in CMake files
  var baseName = ""
  if moduleInfo.name.startsWith("Qt6"):
    baseName = moduleInfo.name.substr(3)  # Remove "Qt6" prefix
  else:
    baseName = moduleInfo.name
  
  # Try various possible CMake dependency file locations
  let cmakePaths = @[
    frameworkPath.splitPath().head / "cmake" / moduleInfo.name / moduleInfo.name & "Dependencies.cmake",
    frameworkPath.splitPath().head / "cmake" / "Qt6" & baseName / "Qt6" & baseName & "Dependencies.cmake"
  ]
  
  for cmakePath in cmakePaths:
    if fileExists(cmakePath):
      moduleInfo.requires = getDependenciesFromCMake(cmakePath)
      break
  
  # Set up libs flags for linking - framework needs to be specified with all dependencies
  moduleInfo.libs = getFrameworkLibsString(moduleInfo)
  
  # Set up CFLAGS - For frameworks, we need to point to Headers directory
  var defineModuleName = baseName
  if defineModuleName.toLower().startsWith("qt"):
    defineModuleName = defineModuleName.substr(2)
  
  # For frameworks, we point directly to the Headers directory inside the framework
  # Also expose the flat include/ dir: some iOS modules (e.g. QtQmlIntegration,
  # pulled in by QtQml's qqmlregistration.h) ship headers there rather than in a
  # framework, and `<QtQmlIntegration/qqmlintegration.h>` only resolves via -I.
  moduleInfo.cflags = "-F${libdir} -I${includedir} -I${libdir}/" & frameworkName & ".framework/Headers -DQT_" & defineModuleName.toUpper() & "_LIB"
  
  return moduleInfo

proc parsePrlFile*(filePath: string): QtModule =
  var moduleInfo = QtModule()
  let content = readFile(filePath)
  
  # Check if it's a static library and/or iOS library
  moduleInfo.isStatic = isStaticLibrary(content)
  moduleInfo.isIOS = isIOSLibrary(filePath)
  
  # Store the path to the library file
  moduleInfo.libPath = getLibraryDir(filePath)
  
  # For iOS framework, get the framework name directly from the path
  let frameworkName = parseFrameworkName(filePath)
  
  for line in content.splitLines():
    if line.startsWith("QMAKE_PRL_BUILD_DIR"):
      continue
      
    if line.startsWith("QMAKE_PRL_TARGET"):
      let parts = line.split("=")
      if parts.len > 1:
        var libName = parts[1].strip()
        if moduleInfo.isIOS and frameworkName.len > 0:
          # For iOS frameworks, use the framework name
          moduleInfo.libName = frameworkName
          moduleInfo.name = frameworkName
        else:
          # For regular libraries
          moduleInfo.libName = libName
          var baseName = libName
          
          # Clean up the name for pkg-config
          if moduleInfo.isStatic:
            baseName = baseName.replace("lib", "").replace(".a", "")
          else:
            baseName = baseName.replace("lib", "").replace(".so", "")
            
          moduleInfo.name = baseName
        
        moduleInfo.description = moduleInfo.name & " module"
        
    elif line.startsWith("QMAKE_PRL_VERSION"):
      let parts = line.split("=")
      if parts.len > 1:
        moduleInfo.version = parts[1].strip()

    elif line.startsWith("QMAKE_PRL_LIBS_FOR_CMAKE"):
      let parts = line.split("=")
      if parts.len > 1:
        moduleInfo.requires = getDependencies(filePath, content)

    elif line.startsWith("QMAKE_PRL_LIBS") and not line.contains("_FOR_CMAKE"):
      let parts = line.split("=")
      if parts.len > 1:
        var libs = parts[1].strip()
        
        # Clean framework references like -framework $1
        libs = cleanFrameworkReferences(libs)
        
        # Replace QT_INSTALL_LIBS and other path references
        libs = cleanInstallPathReferences(libs)
        
        # Replace semicolons with spaces
        libs = libs.replace(";", " ")
        
        if moduleInfo.isStatic:
          # For static libraries, we need to handle differently
          if moduleInfo.isIOS and frameworkName.len > 0:
            # For iOS static frameworks, use framework linking with dependencies
            moduleInfo.libs = getFrameworkLibsString(moduleInfo) & " " & libs
          else:
            # For regular static libraries. Qt module libs always live in the
            # kit's lib/ dir, which the generated .pc defines as ${libdir}
            # (= ${prefix}/lib) — use it so the path is prefix-relocatable.
            moduleInfo.libs = "-L${libdir} -l" & moduleInfo.name & " " & libs
        else:
          # For dynamic libraries: normalise each token. A blanket
          # replace("lib","-l") corrupts ${libdir} and full-path references
          # (e.g. ${libdir}/libQt6OpenGL_arm64-v8a.so -> /-lQt6OpenGL...), so
          # tokenise instead: convert any full-path library reference to
          # -l<name> (keeping version/arch suffix) and pass through existing
          # -l/-L/system flags unchanged.
          var cleanedTokens: seq[string] = @[]
          for tok in libs.splitWhitespace():
            if tok.len == 0:
              continue
            let fname = tok.splitPath().tail
            if fname.startsWith("lib") and (tok.contains("/") or tok.contains("$")):
              let name = fname.replace(re2"^lib", "")
                              .replace(re2"\.(a|so|dylib)(\.\d+)*$", "")
              cleanedTokens.add("-l" & name)
            else:
              cleanedTokens.add(tok)
          libs = cleanedTokens.join(" ")
          # Qt module libs live in the kit's lib/ dir, exposed by the generated
          # .pc as ${libdir} (= ${prefix}/lib) — use it so the path stays
          # prefix-relocatable instead of being hard-coded to one kit location.
          moduleInfo.libs = "-L${libdir} -l" & moduleInfo.name & " " & libs
        
        # Process any full paths to use -L/-l combination
        moduleInfo.libs = processFullPaths(moduleInfo.libs, "${prefix}")
  
  # If no libs were set yet but we have a framework, set them now with dependencies
  if moduleInfo.libs.len == 0 and moduleInfo.isIOS and frameworkName.len > 0:
    moduleInfo.libs = getFrameworkLibsString(moduleInfo)
  
  # Generate appropriate CFLAGS.
  # Work from the arch-stripped canonical name (Qt6Core, not Qt6Core_arm64-v8a)
  # so the header subdir and feature define are correct. The Qt header subdir is
  # "Qt" + the part after the "Qt<ver>" prefix (Qt6Core -> Core -> QtCore); the
  # feature define is QT_<MODULE>_LIB. `^Qt\d*` strips both the Android form
  # (Qt6Core) and the iOS framework form (QtCore, no version digits).
  let cleanName = cleanLibraryName(moduleInfo.name)
  let moduleSuffix = cleanName.replace(re2"^Qt\d*", "")
  let includeSubdir = "Qt" & moduleSuffix
  let defineModuleName = moduleSuffix

  if moduleInfo.isIOS:
    # For iOS frameworks, point directly to the Headers directory
    # See parseFramework: also add the flat include/ dir for header-only iOS
    # modules (e.g. QtQmlIntegration) that aren't packaged as frameworks.
    moduleInfo.cflags = "-F${libdir} -I${includedir} -I${libdir}/" & moduleInfo.libName & ".framework/Headers -DQT_" & defineModuleName.toUpper() & "_LIB"
  else:
    moduleInfo.cflags = "-I${includedir} -I${includedir}/" & includeSubdir & " -DQT_" & defineModuleName.toUpper() & "_LIB"
  
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

proc scanForFrameworks(dir: string, outputDir: string, prefix: string, hostBins: string) =
  ## Recursively scan for frameworks and generate .pc files for them
  echo "Scanning for frameworks in: ", dir
  for kind, path in walkDir(dir):
    if kind == pcDir and path.endsWith(".framework"):
      echo "Found framework: ", path
      let module = parseFramework(path)
      if module.name.len > 0:  # Only process if we have a valid module
        generatePcFile(module, outputDir, prefix, hostBins)
    elif kind == pcDir:
      scanForFrameworks(path, outputDir, prefix, hostBins)

proc createBaseQtPcFile(outputDir: string, prefix: string, hostBins: string) =
  ## Create a base Qt6.pc file that other Qt modules can depend on
  let host_bins = if hostBins.len > 0: hostBins else: "${prefix}" & DirSep & "bin"
  let content = fmt"""prefix={prefix}
exec_prefix=${{prefix}}
bindir=${{prefix}}{DirSep}bin
libexecdir=${{prefix}}{DirSep}libexec
libdir=${{prefix}}{DirSep}lib
includedir=${{prefix}}{DirSep}include
host_bins={host_bins}

Name: Qt6
Description: Qt6 base module
Version: 6.8.3
Libs: 
Cflags:
"""
  
  let outputPath = joinPath(outputDir, "Qt6.pc")
  echo "Writing base Qt6.pc file to: ", outputPath
  writeFile(outputPath, content)

proc convertPrlToPc*(inputDir, outputDir, prefix, hostBins: string) =
  ## Convert Qt .prl files to pkg-config files
  ## inputDir: Directory containing .prl files
  ## outputDir: Directory where .pc files will be generated
  ## prefix: Installation prefix path for the libraries
  createDir(outputDir)
  
  # Create a base Qt6.pc file first
  createBaseQtPcFile(outputDir, prefix, hostBins)
  
  echo "Scanning directory for .prl files: ", inputDir
  processDirectory(inputDir, outputDir, prefix, hostBins)
  
  echo "Scanning directory for frameworks: ", inputDir
  scanForFrameworks(inputDir, outputDir, prefix, hostBins)

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