#!/usr/bin/env bash
# Usage: fm-set.sh <file> <key> <value>
# フロントマターの key を value に設定する（無ければフロントマター末尾に挿入）。
# GNU/BSD 両対応のため sed -i を使わない。
set -euo pipefail

python3 - "${1:?file}" "${2:?key}" "${3:?value}" <<'PY'
import sys

path, key, value = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    lines = fh.readlines()
if not lines or lines[0].rstrip("\n") != "---":
    sys.exit(f"no frontmatter: {path}")
end = next((i for i in range(1, len(lines)) if lines[i].rstrip("\n") == "---"), None)
if end is None:
    sys.exit(f"unterminated frontmatter: {path}")
for i in range(1, end):
    if lines[i].startswith(key + ":"):
        lines[i] = f"{key}: {value}\n"
        break
else:
    lines.insert(end, f"{key}: {value}\n")
with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
PY
