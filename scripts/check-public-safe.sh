#!/usr/bin/env bash
# Refuses to let server-side security detail reach this repository, which is public.
#
# The rule is not "never mention security". This client makes real defensive choices — features
# built, tested and deliberately given no path to them from any screen — and a maintainer who
# does not know why `delete` has no caller will wire it up. Those notes must stay.
#
# The rule is: **say what this client does and why; never what the server fails to do.**
#
#   good   "held back — destructive and not reversible, withheld until the endpoint contract
#           is confirmed. Do not put a control in front of this without doing that first."
#   bad    "held back — /delete-file takes userId from the body with no token check, so anyone
#           who can reach the host can delete anyone's document."
#
# Both tell a maintainer not to ship it. Only one is a map.
#
# The patterns below are deliberately **structural, not specific**. An earlier version listed the
# exact strings it was suppressing — the counts, the ports, the phrasing — which made the
# blocklist itself a readable index of the findings. A public checker cannot both be specific and
# be safe.
#
# Green here is necessary, not sufficient: it is a regex, and it has already missed real
# findings that a human read caught. Never let a pass substitute for reading the diff.

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
self=':!scripts/check-public-safe.sh'

report() {
  fail=1
  printf '\n\033[31m✗ %s\033[0m\n  %s\n' "$1" "$2"
  shift 2
  printf '%s\n' "$@" | sed 's/^/    /'
}

scan() {
  local name="$1" why="$2" pattern="$3"; shift 3
  local hits
  hits=$(git grep -nIE "$pattern" -- "$@" 2>/dev/null || true)
  [ -n "$hits" ] && report "$name" "$why" "$hits"
}

# 1. The internal reports: the full audit, and the reason this checker exists. They are kept
#    privately. Check history too — deleting a file in a later commit does not remove it from a
#    clone, and this repository is published from a single commit precisely so that holds.
present=$(git ls-files 'ROADMAP.md' 'V1_BUILD_PLAN.md' 'GAPS.md' 'PARITY_PLAN.md' 'REPORT.md' 'ANDROID_PROMPT.md')
[ -n "$present" ] && report "internal report committed" \
  "these are kept privately, not here" "$present"

in_history=$(git log --all --diff-filter=A --name-only --pretty=format: 2>/dev/null \
  | grep -xE '(ROADMAP|V1_BUILD_PLAN|GAPS|PARITY_PLAN|REPORT|ANDROID_PROMPT)\.md' | sort -u)
[ -n "$in_history" ] && report "internal report reachable in history" \
  "a clone hands over every commit, so removing it later does not help" "$in_history"

# 2. Naming a server-side weakness. `LoadState` models an HTTP 401 as a client concept and is
#    exempt; everything else that uses this vocabulary is describing the platform.
scan "server weakness named" \
  "describes what the server fails to do rather than what this client does" \
  '(unauthenticated|no auth|without auth|no token check|not scoped|no owner predicate|no ownership|not enforced|admin bypass|bypassable|requireAuth)' \
  ':!Sources/EmperorCore/LoadState.swift' \
  ':!Emperor/Features/Shared/LoadStateViews.swift' \
  ':!Tests/EmperorCoreTests/LoadStateTests.swift' \
  ':!Tests/EmperorCoreTests/FileLibraryViewModelTests.swift' \
  ':!Tests/EmperorCoreTests/APIClientTests.swift' \
  "$self"

# 3. Prose shaped like instructions for getting past a check.
#
#    The tool registry and its fixtures are exempt: they are legal prompt text, where "briefed
#    to defeat it" means opposing counsel arguing against a petition. Exempting those two paths
#    is right; loosening the pattern so the phrase passes everywhere is not.
scan "phrased as a way in" \
  "reads as what to send to defeat something, not as a description of this client" \
  '((omit|omitting|dropping|removing|sending only)[^.]{0,40}(header|token|check|array)|defeats? (it|the check)|bypass(es|ing)? (that|the|this) check|skips? (those|the|that) check|falls back to the client)' \
  ':!Sources/EmperorCore/Tools' \
  ':!Tests/EmperorCoreTests/Resources' \
  "$self"

# 4. Something a reader can paste into a terminal, or that shows a query missing its predicate.
scan "runnable against a live host" \
  "a request, URL or query someone can use directly" \
  '(curl[^|]*(userId|localhost)|\?userId=|SELECT [^;]*WHERE|localhost:[0-9]+|127\.0\.0\.1|0\.0\.0\.0|Access-Control-Allow-Origin|Access policy)' \
  "$self"

# 5. How well defended the platform is, and what it holds. Not this repository's business.
scan "server posture disclosed" \
  "helps a reader judge the target rather than helping a maintainer" \
  '([0-9]+ (unauthenticated|unprotected|open|public) (route|endpoint)|no server-side revocation|hardcoded[^.]{0,30}(credential|password|key)|plaintext[^.]{0,30}(password|key|credential|token)|real client matters|live client data|does not resolve)' \
  "$self"

# 6. Infrastructure that aids targeting: server paths, shell users, internal hosts.
scan "infrastructure detail" \
  "names a path, account or host that is not this repository's to publish" \
  '(/var/www|/srv/|root@|ecosystem\.[a-z]+\.config)' \
  "$self"

if [ "$fail" -eq 0 ]; then
  printf '\033[32m✓ public-safe\033[0m — no server-side security detail in the tree or its history\n'
else
  printf '\n\033[31mRefusing to call this tree public-safe.\033[0m\n'
  printf 'Rewrite each hit to say what this client does, not what the server fails to do.\n'
  printf 'If a hit is genuinely a false positive, exempt that one path — do not loosen a pattern.\n'
fi
exit "$fail"
