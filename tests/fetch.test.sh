#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/data" "$tmp/runtime"
export XDG_DATA_HOME="$tmp/data"
export XDG_RUNTIME_DIR="$tmp/runtime"
export PATH="$tmp/bin:$PATH"

cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=
printf '%s\n' "$@" >"${FAKE_CURL_ARGS:?}"
while (($#)); do
  if [[ $1 == --output ]]; then output=$2; shift 2; else shift; fi
done
if [[ ${FAKE_CURL_EXIT:-0} != 0 ]]; then exit "$FAKE_CURL_EXIT"; fi
cp "${FAKE_CURL_BODY:?}" "$output"
SH
chmod +x "$tmp/bin/curl"
export FAKE_CURL_ARGS="$tmp/curl.args"

cat >"$tmp/catalog.json" <<'JSON'
[
  {"slug":"plain","name":"Plain","url":"https://radio.example/path","genre":"Jazz"},
  {"slug":"featured","name":"Featured","url":"https://featured.example","featured":true},
  {"slug":"bad","name":"","url":"https://bad.example"}
]
JSON
FAKE_CURL_BODY="$tmp/catalog.json" "$root/subwave-fetch" catalog >"$tmp/out.json"
jq -e 'length == 2 and .[0].slug == "featured" and .[1].url == "https://radio.example"' "$tmp/out.json" >/dev/null
test "$(stat -c %a "$XDG_DATA_HOME/omarchy-subwave/catalog.json")" = 600
grep -Fx 'Omarchy SUB/WAVE/0.1.0' "$tmp/curl.args" >/dev/null

FAKE_CURL_EXIT=22 "$root/subwave-fetch" catalog >"$tmp/cached.json"
cmp "$tmp/out.json" "$tmp/cached.json"
"$root/subwave-fetch" cache >"$tmp/cache-command.json"
cmp "$tmp/out.json" "$tmp/cache-command.json"

cat >"$tmp/now.json" <<'JSON'
{"nowPlaying":{"title":"Track","artist":"Artist","album":"Album","subsonic_id":"abc"},"dj":{"station":"Example","name":"Frequency"},"activeShow":{"name":"Night Drive"},"listeners":{"current":4},"streamOnline":true}
JSON
FAKE_CURL_BODY="$tmp/now.json" "$root/subwave-fetch" now-playing https://radio.example >"$tmp/now-out.json"
jq -e '.online == true and .title == "Track" and .artist == "Artist" and .listeners == 4 and .coverUrl == "https://radio.example/api/cover/abc"' "$tmp/now-out.json" >/dev/null

if "$root/subwave-fetch" now-playing 'https://u:p@radio.example' >/dev/null 2>&1; then
  echo "credentialed URL was accepted" >&2
  exit 1
fi

dd if=/dev/zero of="$tmp/large.json" bs=1048577 count=1 status=none
before=$(sha256sum "$XDG_DATA_HOME/omarchy-subwave/catalog.json")
FAKE_CURL_BODY="$tmp/large.json" "$root/subwave-fetch" catalog >"$tmp/large-out.json"
after=$(sha256sum "$XDG_DATA_HOME/omarchy-subwave/catalog.json")
test "$before" = "$after"
cmp "$tmp/out.json" "$tmp/large-out.json"

echo "subwave-fetch tests passed"
