#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT/build/TestModuleCache"
swiftc -swift-version 5 -module-cache-path "$ROOT/build/TestModuleCache" \
  -import-objc-header "$ROOT/Sources/Crypto.h" \
  "$ROOT/Sources/OffTimer.swift" "$ROOT/Sources/GreeClient.swift" "$ROOT/Tests/ProtocolTests.swift" \
  -o "$ROOT/build/protocol-tests"
"$ROOT/build/protocol-tests"
