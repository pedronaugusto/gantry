"""`jdeps -verbose:class` on compiled classes, with each class's source file.

jdeps names classes; the class file's SourceFile attribute and package
folder name the source that declared it, nested and non-public top-level
classes included. Prints {"jdeps": <unchanged output>, "sources": {class: path}}.
"""
import json
from pathlib import Path
import struct
import subprocess
import sys


def source_file(data):
    """The SourceFile attribute of a class file, or None."""
    count = struct.unpack(">H", data[8:10])[0]
    pool, i, k = [None] * count, 10, 1
    while k < count:
        tag = data[i]
        if tag == 1:
            n = struct.unpack(">H", data[i + 1:i + 3])[0]
            pool[k] = data[i + 3:i + 3 + n].decode("utf-8", "replace")
            i += 3 + n
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            i += 5
        elif tag in (5, 6):
            i, k = i + 9, k + 1
        elif tag in (7, 8, 16, 19, 20):
            i += 3
        elif tag == 15:
            i += 4
        else:
            raise ValueError(f"constant pool tag {tag}")
        k += 1
    i += 6
    i += 2 + 2 * struct.unpack(">H", data[i:i + 2])[0]
    for _ in range(2):  # fields, then methods
        n = struct.unpack(">H", data[i:i + 2])[0]
        i += 2
        for _ in range(n):
            attributes = struct.unpack(">H", data[i + 6:i + 8])[0]
            i += 8
            for _ in range(attributes):
                i += 6 + struct.unpack(">I", data[i + 2:i + 6])[0]
    n = struct.unpack(">H", data[i:i + 2])[0]
    i += 2
    for _ in range(n):
        name, length = pool[struct.unpack(">H", data[i:i + 2])[0]], struct.unpack(">I", data[i + 2:i + 6])[0]
        if name == "SourceFile":
            return pool[struct.unpack(">H", data[i + 6:i + 8])[0]]
        i += 6 + length


jdk, classes, root = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
sources = {}
for path in sorted(classes.rglob("*.class")):
    name = source_file(path.read_bytes())
    if name:
        sources[path.relative_to(classes).as_posix()[:-6].replace("/", ".")] = f"{root}/{path.parent.relative_to(classes).as_posix()}/{name}"
output = subprocess.run([jdk / "bin/jdeps", "-verbose:class", "-filter:none", classes], check=True, capture_output=True, text=True).stdout
json.dump({"jdeps": output, "sources": sources}, sys.stdout, indent=1, sort_keys=True)
