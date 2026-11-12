#!/usr/bin/env bash
# Exact retained iOS Loro package, on macOS, without installing an app or
# touching a simulator. Format/schema compatibility, not iOS transport/UI.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export HARNESS_HEAVY_BUILD_LOCK="${HARNESS_HEAVY_BUILD_LOCK:-$root/../zigfull.lock}"
pkg="$root/apps/nano/compat/swift"
scratch="$root/target/nano-loro-swift"
"$root/scripts/heavy-build.sh" swift build --package-path "$pkg" --scratch-path "$scratch"
bin="$(swift build --package-path "$pkg" --scratch-path "$scratch" --show-bin-path)"
if [[ $# -eq 3 ]]; then "$bin/LoroCompatibility" "$1" "$2" "$3"; fi
# Reuse the existing Swift vector runner and production ChatFrames source,
# adapting only its app-module import and fixture path for a standalone test.
work="$root/target/nano-loro-swift-vectors"
mkdir -p "$work"
python3 - "$root" "$work" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
src = (root/'apps/ios/HarnessTests/Chat2VectorTests.swift').read_text().replace('@testable import Harness\n', '')
a=src.index('    private static let file = ')
b=src.index('\n\n    private func vectors', a)
src=src[:a]+'    private static let file = URL(fileURLWithPath: '+repr(str(root/'protocol/chat2-vectors.json')).replace("'",'"')+')'+src[b:]
(out/'Chat2VectorTests.swift').write_text(src)
methods=['testFrameTypeBytesAndHeaderCap','testEncodesExactBytesAndDecodesThemBack','testDecodeRejectsAndAccepts','testPlansCatchUp','testWalksTheRowCursor','testRowCursorAtTheTopOfTheRange']
(out/'main.swift').write_text('import XCTest\nimport Foundation\nlet suite = Chat2VectorTests.defaultTestSuite\nsuite.run()\nguard let run = suite.testRun, run.hasSucceeded, run.executionCount == '+str(len(methods))+' else { exit(1) }\nprint("Swift chat2 vectors: \\(run.executionCount) tests passed")\n')
PY
frameworks="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
support="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
"$root/scripts/heavy-build.sh" swiftc -F "$frameworks" -I "$support" -L "$support" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$support" -Xlinker -rpath -Xlinker "$frameworks" \
  "$root/apps/ios/Harness/Sync/ChatFrames.swift" "$work/Chat2VectorTests.swift" "$work/main.swift" -o "$work/vectors"
"$work/vectors"
printf 'Swift core executable: %s/LoroCompatibility\n' "$bin"
