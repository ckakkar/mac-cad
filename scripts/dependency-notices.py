"""Copy actual locked dependency license texts into each distributed app."""
import json
import subprocess
import sys
from pathlib import Path

destination = Path(sys.argv[1])
metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform", "aarch64-apple-darwin"], text=True))
included = {node["id"] for node in metadata["resolve"]["nodes"]}
notices = ["mac-cad third-party Rust dependencies (including build dependencies):\n"]
for package in metadata["packages"]:
    if package["name"] == "cad-core" or package["id"] not in included:
        continue
    root = Path(package["manifest_path"]).parent
    prefix = f'{package["name"]}-{package["version"]}'
    notices.append(f'{prefix}: {package.get("license", "See license files")} · {package.get("repository") or package.get("homepage") or "https://crates.io/crates/" + package["name"]}')
    files = [p for p in root.iterdir() if p.is_file() and p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "UNLICENSE"))]
    files += list(Path("licenses").glob(f"{prefix}-LICENSE*"))
    if not files:
        raise SystemExit(f"Missing dependency license text: {prefix}")
    for path in files:
        (destination / f"{prefix}-{path.name}").write_bytes(path.read_bytes())
(destination / "ThirdPartyNotices.txt").write_text("\n".join(notices)+"\n", encoding="utf-8")
