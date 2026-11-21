#!/usr/bin/env bash

# Prints "app=false" only when a pull request changes nothing but
# documentation (docs/ and top-level Markdown). Pushes to main always run the
# gate: a later docs-only push can cancel the run for the code merged before it.
# Any other change, or any doubt about the comparison, prints "app=true".
set -euo pipefail

app=true
range=""
if [[ "${EVENT_NAME:-}" == "pull_request" ]]; then
  range="${PR_BASE:-}...${PR_HEAD:-}"
fi
if [[ -n "$range" ]] && changed="$(git diff --name-only --no-renames "$range")" && [[ -n "$changed" ]]; then
  echo "Changed files:" >&2
  echo "$changed" >&2
  if ! grep -Ev '^(docs/.*|[^/]+\.md)$' <<<"$changed" >/dev/null; then
    app=false
  fi
fi
echo "Run the macOS gate: $app" >&2
echo "app=$app"
