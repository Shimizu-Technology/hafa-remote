#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/hafa-clang-probe-test.XXXXXX")"
trap 'rm -rf -- "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/bin"

cat >"$fixture_dir/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "--find clang" ]] || exit 91
printf '%s\n' "$HAFA_FIXTURE_COMPILER"
SH
cat >"$fixture_dir/compiler" <<'PY'
#!/usr/bin/env python3
import os
import sys

if all(flag in sys.argv for flag in ('-v', '-E', '-dM')):
    # stderr first reproduces a parent that reads stdout to EOF before stderr.
    os.write(2, b'e' * 65536)
    os.write(1, b'o' * 65536)
    sys.exit(int(os.environ.get('HAFA_FIXTURE_EXIT', '0')))
print('forwarded:' + '|'.join(sys.argv[1:]))
sys.exit(int(os.environ.get('HAFA_FIXTURE_EXIT', '0')))
PY
chmod +x "$fixture_dir/bin/xcrun" "$fixture_dir/compiler"

PATH="$fixture_dir/bin:$PATH" HAFA_FIXTURE_COMPILER="$fixture_dir/compiler" \
  python3 - "$repo_root/scripts/xcode-clang-probe.sh" <<'PY'
import os
import signal
import subprocess
import sys
import threading

wrapper = sys.argv[1]
for expected_status in (0, 7):
    environment = dict(os.environ, HAFA_FIXTURE_EXIT=str(expected_status))
    process = subprocess.Popen(
        [wrapper, '-v', '-E', '-dM', '-x', 'c', '-c', '/dev/null'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=environment, start_new_session=True,
    )
    def expire(process=process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = threading.Timer(10, expire)
    deadline.start()
    try:
        output = process.stdout.read()
        errors = process.stderr.read()
        status = process.wait()
    finally:
        deadline.cancel()
        process.stdout.close()
        process.stderr.close()
    assert output == b'o' * 65536, 'probe stdout changed or blocked'
    assert errors == b'e' * 65536, 'probe stderr changed or blocked'
    assert status == expected_status, 'compiler status was not preserved'

environment = dict(os.environ, HAFA_FIXTURE_EXIT='9')
result = subprocess.run(
    [wrapper, '-c', 'synthetic source.c', '-o', 'synthetic output.o'],
    capture_output=True, env=environment, timeout=10,
)
assert result.returncode == 9
assert result.stdout == b'forwarded:-c|synthetic source.c|-o|synthetic output.o\n'
assert result.stderr == b''
print('Xcode clang probe regression checks passed')
PY
