#!/usr/bin/env bash
# Build dist/lucenbar-lite-<version>.plasmoid from the working tree.
set -euo pipefail
cd "$(dirname "$0")"

python3 - <<'EOF'
import json, pathlib, zipfile

version = json.load(open("metadata.json"))["KPlugin"]["Version"]
out = pathlib.Path(f"dist/lucenbar-lite-{version}.plasmoid")
out.parent.mkdir(exist_ok=True)
out.unlink(missing_ok=True)

roots = ["metadata.json", "contents", "scripts", "LICENSE", "NOTICE.md", "README.md", "CHANGELOG.md"]
files = []
for root in map(pathlib.Path, roots):
    files += [root] if root.is_file() else sorted(p for p in root.rglob("*") if p.is_file())
files = [p for p in files if "__pycache__" not in p.parts and p.suffix != ".pyc"]

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for p in files:
        info = zipfile.ZipInfo(str(p), date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = (0o755 if p.stat().st_mode & 0o111 else 0o644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, p.read_bytes())
print(out)
EOF
