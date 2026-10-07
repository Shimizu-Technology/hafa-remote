#!/usr/bin/env bash

# Preserve Apple's compiler and arguments while avoiding a sequential stdout /
# stderr drain deadlock in Xcode's compiler-capability probe. Compilation and
# linking invocations bypass the capture path entirely.
set -euo pipefail

compiler="$(xcrun --find clang)"
has_verbose=0
has_preprocess=0
has_macros=0
for argument in "$@"; do
  case "$argument" in
    -v) has_verbose=1 ;;
    -E) has_preprocess=1 ;;
    -dM) has_macros=1 ;;
  esac
done
if [[ "$has_verbose$has_preprocess$has_macros" != "111" ]]; then
  exec "$compiler" "$@"
fi

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/hafa-clang-probe.XXXXXX")"
trap 'rm -rf -- "$probe_dir"' EXIT
set +e
"$compiler" "$@" >"$probe_dir/stdout" 2>"$probe_dir/stderr"
compiler_status=$?
set -e

# Close stdout before replaying stderr: a parent that consumes stdout to EOF
# first can then drain stderr even when both outputs exceed a pipe's capacity.
cat "$probe_dir/stdout"
exec 1>&-
cat "$probe_dir/stderr" >&2
exit "$compiler_status"
