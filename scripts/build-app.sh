#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Usage: scripts/build-app.sh [debug|release]" >&2
    exit 2
fi
scripts/swift.sh build -c "$configuration" --product VisioRhytm
binary_path="$(scripts/swift.sh build -c "$configuration" --show-bin-path)"
app_path="$project_root/dist/VisioRhytm.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/VisioRhytm" "$app_path/Contents/MacOS/VisioRhytm"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
echo "Built: $app_path"
echo "Run: open \"$app_path\""
