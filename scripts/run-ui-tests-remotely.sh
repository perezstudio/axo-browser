#!/bin/bash
# Runs Axo's UI tests on a GitHub-hosted Mac (.github/workflows/ui-tests.yml) instead of this
# one, so they don't take over the screen, keyboard, and mouse. Tests the current branch as
# pushed to GitHub, waits for the run, and on failure downloads the result bundle.
#
#   scripts/run-ui-tests-remotely.sh                      # AxoUITests
#   scripts/run-ui-tests-remotely.sh AxoUITests/AxoUITests/testNavigationBarPlacement
#   scripts/run-ui-tests-remotely.sh all                  # the whole Axo test plan
#
# Needs the GitHub CLI (gh), signed in. The workflow must exist on the branch.
set -euo pipefail

ONLY_TESTING="${1:-AxoUITests}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
  echo "error: HEAD is detached. Check out a pushed branch; the run tests a branch on GitHub." >&2
  exit 1
fi
HEAD_SHA="$(git rev-parse HEAD)"

git fetch --quiet origin "$BRANCH" 2>/dev/null || true
if [[ "$(git rev-parse --verify --quiet "origin/$BRANCH" || true)" != "$HEAD_SHA" ]]; then
  echo "error: origin/$BRANCH isn't at HEAD ($HEAD_SHA). Push the branch first; the run tests what's on GitHub." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "note: Uncommitted changes aren't part of the run."
fi

# Runs created from now on are this dispatch's, so an earlier dispatch of the same commit isn't
# mistaken for it. (Five seconds early, in case this Mac's clock runs ahead of GitHub's.)
SINCE="$(date -u -v-5S +%Y-%m-%dT%H:%M:%SZ)"
gh workflow run ui-tests.yml --ref "$BRANCH" -f only_testing="$ONLY_TESTING"

# The run takes a moment to appear.
RUN_ID=""
for _ in $(seq 1 30); do
  RUN_ID="$(gh run list --workflow ui-tests.yml --branch "$BRANCH" --event workflow_dispatch \
    --commit "$HEAD_SHA" --limit 5 --json databaseId,createdAt \
    --jq "[.[] | select(.createdAt >= \"$SINCE\")] | sort_by(.createdAt) | last | .databaseId // empty")"
  [[ -n "$RUN_ID" ]] && break
  sleep 2
done
if [[ -z "$RUN_ID" ]]; then
  echo "error: Couldn't find the run. Check the Actions tab." >&2
  exit 1
fi

if gh run watch "$RUN_ID" --exit-status --interval 30; then
  echo "UI tests passed."
elif [[ "$(gh run view "$RUN_ID" --json conclusion --jq .conclusion)" == "cancelled" ]]; then
  # A newer run of the same branch replaces an older one (the workflow's concurrency group).
  echo "The run was cancelled, probably by a newer run of $BRANCH: gh run view $RUN_ID" >&2
  exit 1
else
  DEST="$(mktemp -d "${TMPDIR:-/tmp}/axo-ui-tests.XXXXXX")"
  gh run download "$RUN_ID" --dir "$DEST" || true
  echo "UI tests failed. Logs: gh run view $RUN_ID --log-failed"
  echo "Result bundle: $DEST"
  exit 1
fi
