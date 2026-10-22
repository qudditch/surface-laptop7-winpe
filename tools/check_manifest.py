"""Validate the WinPE driver manifest against the driver root and a WinPE INF list."""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = Path(sys.argv[2])
winpe_list = Path(sys.argv[3])

# Collect INF file names shipped in the WinPE image.
present = set()
for line in winpe_list.read_text(encoding="utf-8", errors="replace").splitlines():
    m = re.search(r"Windows\\INF\\([^\\]+\.inf)\s*$", line.strip(), re.I)
    if m:
        present.add(m.group(1).lower())

entries = []
for raw in manifest.read_text(encoding="utf-8").splitlines():
    line = raw.split("#", 1)[0].strip()
    if line:
        entries.append(line)

print(f"manifest entries : {len(entries)}")
print(f"WinPE INF files  : {len(present)}")
print()

problems = 0
for folder in entries:
    d = root / folder
    if not d.is_dir():
        print(f"MISSING FOLDER  : {folder}")
        problems += 1
        continue
    infs = sorted(p for p in d.glob("*.inf"))
    if len(infs) != 1:
        print(f"INF COUNT {len(infs):<3} : {folder} -> {[p.name for p in infs]}")
    for inf in infs:
        raw = inf.read_bytes()
        text = None
        for enc in ("utf-16", "utf-8-sig", "cp949", "latin-1"):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        if text is None:
            print(f"UNDECODABLE     : {inf}")
            problems += 1
            continue
        for m in re.findall(r"^\s*Include\s*=\s*(.+)$", text, re.M | re.I):
            for name in m.split(","):
                name = name.strip().split(";")[0].strip().lower()
                if not name:
                    continue
                if name not in present:
                    print(f"INCLUDE MISSING : {folder}/{inf.name} -> {name}")
                    problems += 1

print()
print(f"problems: {problems}")
