import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("drivers")
rows = []
for inf in sorted(root.rglob("*.inf")):
    raw = inf.read_bytes()
    text = None
    for enc in ("utf-16", "utf-8-sig", "cp949", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    if text is None:
        continue
    ids = sorted(set(re.findall(r"(?:ACPI|USB)\\[A-Za-z0-9_&]+", text)))
    cls = re.search(r"^\s*Class\s*=\s*(\S+)", text, re.M | re.I)
    ver = re.search(r"^\s*DriverVer\s*=\s*(.+)$", text, re.M | re.I)
    rows.append((str(inf.parent.name) + "/" + inf.name,
                 cls.group(1) if cls else "-",
                 ver.group(1).strip() if ver else "-",
                 ",".join(ids) if ids else "-"))

width = max(len(r[0]) for r in rows)
for name, cls, ver, ids in rows:
    print(f"{name:<{width}}  {cls:<12} {ids}")
