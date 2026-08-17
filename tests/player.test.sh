#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  XDG_RUNTIME_DIR="$tmp/runtime" XDG_DATA_HOME="$tmp/data" "$root/subwave-player" stop >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/data" "$tmp/runtime"
export XDG_DATA_HOME="$tmp/data"
export XDG_RUNTIME_DIR="$tmp/runtime"
export PATH="$tmp/bin:$PATH"
export FAKE_MPV_ARGS="$tmp/mpv.args"
export FAKE_MPV_VOLUME="$tmp/volume"

cat >"$tmp/bin/mpv-ipc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r request
id=$(jq -r '.request_id' <<<"$request")
action=$(jq -r '.command[0]' <<<"$request")
property=$(jq -r '.command[1] // ""' <<<"$request")
if [[ $action == get_property && $property == pause ]]; then data=false
elif [[ $action == get_property && $property == volume ]]; then data=$(cat "$FAKE_MPV_VOLUME" 2>/dev/null || printf 70)
elif [[ $action == set_property && $property == volume ]]; then
  jq -r '.command[2]' <<<"$request" >"$FAKE_MPV_VOLUME"
  data=null
else data=null
fi
jq -cn --argjson id "$id" --argjson data "$data" '{request_id:$id,error:"success",data:$data}'
SH
chmod +x "$tmp/bin/mpv-ipc"

cat >"$tmp/bin/mpv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$FAKE_MPV_ARGS"
socket=
for arg in "$@"; do
  [[ $arg == --input-ipc-server=* ]] && socket=${arg#*=}
done
[[ -n $socket ]]
exec socat "UNIX-LISTEN:$socket,fork" "SYSTEM:$PWD/tests/fake-unused" 2>/dev/null
SH
chmod +x "$tmp/bin/mpv"

# Override socat for the fake MPV listener and for client calls.
real_socat=$(command -v socat)
export REAL_SOCAT="$real_socat"
cat >"$tmp/bin/socat" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == UNIX-LISTEN:* ]]; then
  exec "$REAL_SOCAT" "$1" "SYSTEM:$PATH" >/dev/null
fi
exec "$REAL_SOCAT" "$@"
SH
chmod +x "$tmp/bin/socat"

# Replace the listener fake with a direct real-socat command after PATH setup.
cat >"$tmp/bin/mpv" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$@" >"\$FAKE_MPV_ARGS"
socket=
for arg in "\$@"; do [[ \$arg == --input-ipc-server=* ]] && socket=\${arg#*=}; done
exec "$real_socat" "UNIX-LISTEN:\$socket,fork" "SYSTEM:$tmp/bin/mpv-ipc"
SH
chmod +x "$tmp/bin/mpv"

"$root/subwave-player" status | jq -e '.running == false and .volume == 70' >/dev/null
if "$root/subwave-player" play 'file:///tmp/audio' 'Bad' >/dev/null 2>&1; then
  echo "unsafe player URL was accepted" >&2
  exit 1
fi
"$root/subwave-player" play 'https://radio.example/path' 'Example Radio' | jq -e '.running == true' >/dev/null
grep -Fx -- '--no-video' "$FAKE_MPV_ARGS" >/dev/null
grep -E '^--input-ipc-server=' "$FAKE_MPV_ARGS" >/dev/null
grep -Fx -- 'https://radio.example/stream.mp3' "$FAKE_MPV_ARGS" >/dev/null
"$root/subwave-player" volume 95 | jq -e '.volume == 95' >/dev/null
if "$root/subwave-player" volume 101 >/dev/null 2>&1; then
  echo "out-of-range volume was accepted" >&2
  exit 1
fi
"$root/subwave-player" toggle | jq -e '.running == true' >/dev/null
"$root/subwave-player" stop | jq -e '.running == false' >/dev/null

mkdir -p "$XDG_RUNTIME_DIR/omarchy-subwave"
start=$(awk '{print $22}' "/proc/$$/stat")
printf '%s %s\n' "$$" "$((start + 1))" >"$XDG_RUNTIME_DIR/omarchy-subwave/player.pid"
"$root/subwave-player" stop | jq -e '.running == false' >/dev/null
kill -0 "$$"

echo "subwave-player tests passed"
