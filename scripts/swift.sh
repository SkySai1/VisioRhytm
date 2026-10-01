#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/swift-module-cache"
command_name="${1:-build}"
if [[ $# -gt 0 ]]; then shift; fi
options=(--disable-sandbox --cache-path "$project_root/.build/package-cache")
if [[ "$command_name" == "test" ]]; then
    options+=(--disable-xctest)
    developer_path="$(xcode-select -p)"
    testing_path="$developer_path/Library/Developer/Frameworks"
    if [[ -d "$testing_path/Testing.framework" ]]; then
        options+=(-Xswiftc -F -Xswiftc "$testing_path" -Xlinker -rpath -Xlinker "$testing_path"
                  -Xlinker -rpath -Xlinker "$developer_path/Library/Developer/usr/lib")
    fi
fi
exec swift "$command_name" "${options[@]}" "$@"
