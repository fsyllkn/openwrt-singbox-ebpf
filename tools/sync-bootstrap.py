#!/usr/bin/env python3
"""Embed the shared POSIX download library in the standalone SSH bootstrap."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
START = "# BEGIN SHARED DOWNLOAD LIBRARY\n"
END = "# END SHARED DOWNLOAD LIBRARY\n"
path = ROOT / "quick-install.sh"
source = path.read_text()
block = START + (ROOT / "scripts/download.sh").read_text().rstrip("\n") + "\n" + END
if START in source:
    before, rest = source.split(START, 1)
    _, after = rest.split(END, 1)
    source = before + block + after
else:
    marker = "usage() {\n"
    if source.count(marker) != 1:
        raise SystemExit("Cannot identify standalone bootstrap insertion point")
    source = source.replace(marker, block + "\n" + marker, 1)
path.write_text(source)
print("Standalone download library synchronized.")
