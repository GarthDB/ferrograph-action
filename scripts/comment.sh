#!/usr/bin/env bash
# Sticky PR comment: update the comment containing the marker, else create one.
# Falls back to the job summary on fork PRs, non-PR events, or any API failure; never fails.
# Env: REPORT, REPO, PR_NUMBER, IS_FORK, GH_TOKEN, GITHUB_STEP_SUMMARY.
set -uo pipefail

MARKER='<!-- ferrograph -->'
summary() { cat "$REPORT" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

if [ "${IS_FORK:-false}" = true ] || [ -z "${PR_NUMBER:-}" ]; then
  echo "Not commenting (fork PR or no pull request); writing job summary."
  summary
  exit 0
fi

api="repos/$REPO/issues"
id="$(gh api --paginate "$api/$PR_NUMBER/comments" --jq ".[] | select(.body | contains(\"$MARKER\")) | .id" 2>/dev/null | sed -n 1p)"
if [ -n "$id" ]; then
  gh api --method PATCH "$api/comments/$id" --field "body=@$REPORT" >/dev/null
else
  gh api --method POST "$api/$PR_NUMBER/comments" --field "body=@$REPORT" >/dev/null
fi || { echo "::warning::Could not post PR comment (needs pull-requests: write); wrote job summary instead."; summary; }
exit 0
