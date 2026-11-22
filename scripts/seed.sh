#!/bin/zsh
# Exports every template of this Mac's library into Resources/templates/ so the next package
# ships them to a fresh install. Run before scripts/package.sh.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swiftc -swift-version 5 -Onone Sources/Core/*.swift tools/seedexport/main.swift -lsqlite3 -o .build/export_seeds
.build/export_seeds Resources/templates
du -sh Resources/templates
