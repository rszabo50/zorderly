#!/usr/bin/env python3
"""Package PNG iconset images into the macOS ICNS container."""

from pathlib import Path
import struct
import sys


SIZES = {
    "icp4": "icon_16x16.png",
    "icp5": "icon_32x32.png",
    "icp6": "icon_32x32@2x.png",
    "ic07": "icon_128x128.png",
    "ic08": "icon_256x256.png",
    "ic09": "icon_512x512.png",
    "ic10": "icon_512x512@2x.png",
}


def main(iconset: Path, output: Path) -> None:
    chunks = []
    for kind, filename in SIZES.items():
        data = (iconset / filename).read_bytes()
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"{filename} is not a PNG")
        chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
    output.write_bytes(b"icns" + struct.pack(">I", 8 + sum(map(len, chunks))) + b"".join(chunks))


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
