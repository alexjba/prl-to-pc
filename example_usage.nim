import prl_to_pc

# Example usage as a library
proc main() =
  let 
    inputDir = "/path/to/qt/lib"
    outputDir = "pkgconfig"
    prefix = "/path/to/qt"
    hostBins = "/path/to/qt/bin"
  
  # Use the main conversion function
  convertPrlToPc(inputDir, outputDir, prefix, hostBins)

when isMainModule:
  main() 