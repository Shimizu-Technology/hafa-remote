#!/usr/bin/env bash

# Prints "app=false" only when a CI event changes nothing but documentation
# (docs/ and top-level Markdown). Any other change, or any doubt about the
# comparison, prints "app=true" so the full gate runs.
set -euo pipefail

app=true
range=""
case "${EVENT_NAME:-}" in
  pull_request) range="${PR_BASE:-}...${PR_HEAD:-}" ;;
  push) [[ "${PUSH_BEFORE:-}" =~ ^0*$ ]] || range="$PUSH_BEFORE..${PUSH_AFTER:-}" ;;
esac
if [[ -n "$range" ]] && changed="$(git diff --name-only --no-renames "$range")" && [[ -n "$changed" ]]; then
  echo "Changed files:" >&2
  echo "$changed" >&2
  if ! grep -Ev '^(docs/.*|[^/]+\.md)$' <<<"$changed" >/dev/null; then
    app=false
  fi
fi
echo "Run the macOS gate: $app" >&2
echo "app=$app"
