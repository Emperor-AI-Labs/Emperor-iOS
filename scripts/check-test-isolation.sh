#!/usr/bin/env bash
# Refuses a test suite that shares `HTTPStub` state without clearing it first.
#
# `HTTPStub` records every request into one static box, shared by every suite in the process. A
# class that clears it in `tearDown` alone still leaves its **first** test reading whatever the
# previously-run class left behind — XCTest runs classes in a fixed order, so that is not a race
# but a deterministic failure that moves whenever a suite is renamed.
#
# The reason this needs a gate rather than a convention is that **CI cannot see it**. The core
# job runs `swift test --parallel`, which splits classes across processes, so the two suites
# involved need never meet; the same tree fails serially on a developer's machine and passes
# every time on the runner. `ProjectServiceWireTests` inherited a `/preferred-model` request that
# way, and seven other suites had the identical `tearDown`-only shape.
#
# The rule: any suite that touches `HTTPStub` clears it in `setUp`. Clearing in `tearDown` as
# well is good hygiene and this does not object to it — but it is not a substitute.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0

report() {
  fail=1
  printf '\033[31m✗\033[0m %s\n' "$1"
}

# Walks each file class-by-class. The shapes here are the ones this repository actually uses —
# `final class X: XCTestCase`, and a `setUp` whose body is a handful of lines — so this parses
# them directly rather than pretending to understand Swift.
offenders=$(
  awk '
    # A class is only judged once its last line has been read, so the verdict is flushed on the
    # next class, at the top of the next file, and at the end. `clsfile` is remembered because by
    # flush time FILENAME may already have moved on.
    function flush() {
      if (cls != "" && uses && !clean) print clsfile ":" cls
      cls = ""; uses = 0; clean = 0; insetup = 0
    }
    FNR == 1 { flush() }
    /^(final )?class [A-Za-z0-9_]+: *XCTestCase/ {
      flush()
      cls = $0
      sub(/^(final )?class /, "", cls)
      sub(/:.*$/, "", cls)
      clsfile = FILENAME
      next
    }
    /override func setUp/ { insetup = 1 }
    insetup && /HTTPStub\.reset\(\)/ { clean = 1 }
    insetup && /^    \}/ { insetup = 0 }
    /HTTPStub/ { uses = 1 }
    END { flush() }
  ' Tests/EmperorCoreTests/*.swift
)

if [ -n "$offenders" ]; then
  while IFS= read -r hit; do
    report "$hit — touches HTTPStub but does not reset it in setUp"
  done <<< "$offenders"
fi

if [ "$fail" -eq 0 ]; then
  printf '\033[32m✓ test-isolation\033[0m — every HTTPStub suite starts from a cleared stub\n'
else
  printf '\n\033[31mA suite can inherit another suite'"'"'s requests.\033[0m\n'
  printf 'Add to the class:\n\n'
  printf '    override func setUp() {\n        super.setUp()\n        HTTPStub.reset()\n    }\n\n'
  printf 'Resetting in tearDown alone does not cover the first test in the class.\n'
fi
exit "$fail"
