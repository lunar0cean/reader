"""Restore the original fonts from bounded, compressed source pieces."""
import gzip
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[2]
source = root / "ipad-reader/FontSources"
manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
for entry in manifest:
    relative = pathlib.PurePosixPath(entry["target"])
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit("Invalid font target")
    parts = entry["parts"]
    if not all(re.fullmatch(r"font-\d{2}-\d{2}\.gzpart", name) for name in parts):
        raise SystemExit("Invalid font source piece")
    data = gzip.decompress(b"".join((source / name).read_bytes() for name in parts))
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    print("Restored", entry["target"], len(data))
