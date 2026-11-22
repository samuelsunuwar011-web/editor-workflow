#!/bin/zsh
# Builds Core + Tests into a self-test runner and runs it.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swiftc -swift-version 5 -Onone -g Sources/Core/*.swift Tests/main.swift -lsqlite3 -o .build/selftest
.build/selftest
