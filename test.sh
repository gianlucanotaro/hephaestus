#!/bin/zsh
# Runs the unit tests with only Command Line Tools installed (no Xcode).
# CLT ships Swift Testing but SwiftPM doesn't add its framework path, and the _Testing_Foundation
# cross-import overlay has no module, so we add -F/-rpath ourselves and disable cross-import overlays.
set -euo pipefail
cd "$(dirname "$0")"
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xswiftc -F -Xswiftc "$F" \
  -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
