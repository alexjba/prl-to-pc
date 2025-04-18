# prl-to-pc

A Nim module to convert Qt's `.prl` (QMAKE library dependency) files to pkg-config (`.pc`) files.

## Installation

```bash
nimble install prl_to_pc
```

## Usage

### As a Command Line Tool

```bash
prl_to_pc <input_dir> <output_dir> <prefix_dir> <hosts_bin>
```

This will scan the `input_dir` for `.prl` files and generate corresponding `.pc` files in the `output_dir`.

### As a Nimble Task

In your nimble file, you can import and use the task:

```nim
import prl_to_pc

task convertPrl, "Convert .prl files to .pc files":
  convertPrlToPc("path/to/prl/files", "path/to/output", "path/prefix", "path/to/hosts/bin")
```

Or run `nimble convert "input" "output", "prefix", "host_bin"`

### As a Library

```nim
import prl_to_pc

# Convert a single file
let data = parsePrlFile("path/to/library.prl")
generatePcFile(data, "output/directory", "prefix")

# Convert all files in a directory
convertPrlToPc("input/directory", "output/directory", "prefix")
```

## License

This project is licensed under the MIT License - see the LICENSE file for details. 