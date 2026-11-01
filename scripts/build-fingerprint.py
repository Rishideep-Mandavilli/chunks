import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
paths = list((root / "Sources").rglob("*.swift"))
paths += [root / name for name in (
    "Package.swift", "scripts/make-app.sh", "scripts/Chunks.entitlements",
    "scripts/build-fingerprint.py",
)]
fingerprint = hashlib.sha256()
for path in sorted(paths):
    name = str(path.relative_to(root)).encode()
    content = path.read_bytes()
    fingerprint.update(len(name).to_bytes(8, "big") + name)
    fingerprint.update(len(content).to_bytes(8, "big") + content)
print(fingerprint.hexdigest())
