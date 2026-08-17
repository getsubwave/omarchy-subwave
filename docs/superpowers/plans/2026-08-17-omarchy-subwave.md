# Omarchy SUB/WAVE Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an installable Omarchy shell plugin that plays a configured self-hosted SUB/WAVE station and every station in the public community directory.

**Architecture:** A manifest-backed QML bar widget and overlay delegate pure list logic to `StationModel.js` and all network/player process work to two hardened Bash helpers. The helpers exchange bounded JSON through atomic cache/status files, while `mpv-mpris` exposes playback to Omarchy's existing media service.

**Tech Stack:** Omarchy shell 4 / Quickshell QML, JavaScript, Bash, `curl`, `jq`, `mpv`, `mpv-mpris`, Node's built-in assertion/VM APIs, shell integration tests.

**Spec:** `docs/superpowers/specs/2026-08-17-omarchy-subwave-design.md`

## Global Constraints

- Plugin manifest schema is version `1`; plugin id is exactly `getsubwave.radio`.
- The repository root must remain directly installable with `omarchy plugin add https://github.com/getsubwave/omarchy-subwave.git --enable`.
- The only remote directory source is `https://www.getsubwave.com/stations.json`.
- Station playback uses the normalized origin plus the fixed `/stream.mp3` path.
- Accept only credential-free `http` and `https` origins; reject fragments, control characters, and unsupported schemes.
- Do not accept, persist, or expose listener-auth credentials in version 1.
- Use only packages already shipped by Omarchy: Bash, coreutils, `curl`, `jq`, `mpv`, `mpv-mpris`, and Quickshell.
- Runtime files live under `$XDG_RUNTIME_DIR/omarchy-subwave/`; persistent non-secret files live under `${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-subwave/`.
- All cache and status writes are temporary-file-plus-rename atomic writes with user-only permissions.
- Remote strings are data only: never evaluate them or interpolate them into a shell command.
- Do not edit `/usr/share/omarchy/`; it is reference-only.

## File Map

- `manifest.json` — Omarchy plugin identity, entry points, kinds, and bar metadata.
- `StationModel.js` — pure origin, catalog, configured-station, sorting, and search functions shared by QML and Node tests.
- `BarWidget.qml` — bar label, tooltip, gestures, player status watch, selected-station now-playing poll, and overlay summon.
- `StationPicker.qml` — overlay lifecycle, catalog/search/list UI, bounded live-probe queue, selection, and playback handoff.
- `subwave-fetch` — size-limited catalog/cache and now-playing client with a stable JSON output contract.
- `subwave-player` — verified `mpv` lifecycle, IPC transport actions, volume persistence, and atomic status.
- `tests/model.test.mjs` — pure JavaScript behavioral tests.
- `tests/fetch.test.sh` — fake-network contract, limits, cache, and failure tests.
- `tests/player.test.sh` — fake-player lifecycle, IPC, PID, and volume tests.
- `tests/run` — one command for every project test plus manifest/QML validation when available.
- `.github/workflows/validate.yml` — CI for executable bits, model/shell tests, and manifest structure.
- `README.md` — install, configure, controls, privacy, removal, troubleshooting, and development.
- `LICENSE` — MIT license.
- `preview.png` — marketplace/repository preview captured from the live plugin.

---

### Task 1: Manifest and Pure Station Model

**Files:**
- Create: `manifest.json`
- Create: `StationModel.js`
- Create: `tests/model.test.mjs`
- Create: `tests/run`
- Create: `LICENSE`
- Create: `BarWidget.qml` (valid manifest entry-point skeleton; completed in Task 4)
- Create: `StationPicker.qml` (valid manifest entry-point skeleton; completed in Task 4)

**Interfaces:**
- Consumes: Omarchy manifest schema version 1 and the community station fields `slug`, `name`, `url`, `location`, `country`, `operator`, `genre`, `description`, `featured`, and `submitted`.
- Produces: `normalizeOrigin(value) -> string`, `normalizeCatalog(value) -> Station[]`, `mergeConfigured(stations, stationUrl) -> Station[]`, `searchStations(stations, query) -> Station[]`, and `singleLine(value, limit) -> string`.
- Produces normalized station records with exact keys: `{slug,name,url,location,country,operator,genre,description,featured,submitted,isConfigured}`.

- [ ] **Step 1: Write the model test harness and failing origin tests**

Create `tests/model.test.mjs` with a VM harness compatible with QML-style plain JavaScript:

```js
import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"
import { fileURLToPath } from "node:url"

const testDir = path.dirname(fileURLToPath(import.meta.url))
const source = fs.readFileSync(path.join(testDir, "..", "StationModel.js"), "utf8")
const model = { Array, Boolean, JSON, Math, Number, Object, RegExp, String, URL }
vm.createContext(model)
vm.runInContext(source, model)

assert.equal(model.normalizeOrigin(" https://radio.example.com/path/ "), "https://radio.example.com")
assert.equal(model.normalizeOrigin("http://radio.example.com:7700"), "http://radio.example.com:7700")
assert.equal(model.normalizeOrigin("https://user:pass@radio.example.com"), "")
assert.equal(model.normalizeOrigin("file:///tmp/stream"), "")
assert.equal(model.normalizeOrigin("https://radio.example.com/#secret"), "")
assert.equal(model.normalizeOrigin("https://radio.example.com/\nnext"), "")
```

- [ ] **Step 2: Run the model test and verify the expected failure**

Run: `node tests/model.test.mjs`

Expected: FAIL with `ENOENT` for `StationModel.js`.

- [ ] **Step 3: Implement origin normalization and bounded text**

Create `StationModel.js` with constants `MAX_STATIONS = 200` and `MAX_FIELD = 512`. Implement:

```js
function singleLine(value, limit) {
  var cap = Math.max(0, Math.min(MAX_FIELD, Number(limit) || MAX_FIELD))
  return String(value || "").replace(/[\r\n\t\u0000-\u001f\u007f]+/g, " ").trim().slice(0, cap)
}

function normalizeOrigin(value) {
  var raw = String(value || "").trim()
  if (!raw || /[\u0000-\u001f\u007f]/.test(raw)) return ""
  try {
    var parsed = new URL(raw)
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return ""
    if (parsed.username || parsed.password || parsed.hash) return ""
    return parsed.origin
  } catch (error) {
    return ""
  }
}
```

- [ ] **Step 4: Add failing catalog, merge, sort, and search tests**

Append concrete cases covering:

```js
const rows = model.normalizeCatalog([
  { slug: "zeta", name: "Zeta", url: "https://zeta.example", genre: "Jazz" },
  { slug: "featured", name: "Featured", url: "https://featured.example", featured: true },
  { slug: "bad", name: "", url: "https://bad.example" },
  { slug: "creds", name: "Creds", url: "https://u:p@bad.example" }
])
assert.deepEqual(Array.from(rows, row => row.slug), ["featured", "zeta"])

const merged = model.mergeConfigured(rows, "https://zeta.example/listen")
assert.equal(merged.length, 2)
assert.equal(merged[0].slug, "zeta")
assert.equal(merged[0].isConfigured, true)

const synthetic = model.mergeConfigured(rows, "https://mine.example")
assert.equal(synthetic[0].slug, "__configured")
assert.equal(synthetic[0].name, "My station")
assert.equal(synthetic[0].url, "https://mine.example")

assert.deepEqual(
  Array.from(model.searchStations(synthetic, "jazz"), row => row.slug),
  ["zeta"]
)
assert.equal(model.normalizeCatalog(Array.from({ length: 250 }, (_, i) => ({
  slug: `s-${i}`, name: `Station ${i}`, url: `https://s-${i}.example`
}))).length, 200)
```

Expected: FAIL because the catalog functions are undefined.

- [ ] **Step 5: Implement catalog normalization, configured merge, and search**

Implement each function without QML-only syntax so Node can execute the same file. Normalize every optional string through `singleLine`; derive a fallback slug from the station name; discard rows without a valid name/origin; deduplicate by origin; sort featured first and then by case-insensitive name; cap after sorting. `mergeConfigured` promotes an origin match or prepends `{slug:"__configured",name:"My station",...,isConfigured:true}`. `searchStations` returns all rows for an empty query and otherwise searches the concatenated normalized fields.

- [ ] **Step 6: Add the manifest, test runner, and license**

Create `manifest.json` exactly around this contract:

```json
{
  "schemaVersion": 1,
  "id": "getsubwave.radio",
  "name": "SUB/WAVE Radio",
  "version": "0.1.0",
  "author": "SUB/WAVE",
  "license": "MIT",
  "description": "Listen to your SUB/WAVE station and discover community stations from the Omarchy bar.",
  "homepage": "https://github.com/getsubwave/omarchy-subwave",
  "repository": "https://github.com/getsubwave/omarchy-subwave",
  "keywords": ["radio", "subwave", "music", "mpris"],
  "kinds": ["overlay", "bar-widget"],
  "keepLoaded": true,
  "entryPoints": { "overlay": "StationPicker.qml", "barWidget": "BarWidget.qml" },
  "barWidget": {
    "displayName": "SUB/WAVE Radio",
    "description": "SUB/WAVE community radio player",
    "category": "Media",
    "allowMultiple": false,
    "defaultSection": "left"
  }
}
```

Create `tests/run` as an executable Bash script that resolves the repository root, runs `node tests/model.test.mjs`, then conditionally runs `omarchy plugin validate "$root"` and `qmllint -I /usr/share/omarchy/shell` once QML entry points exist. Add the standard MIT license text with year 2026 and copyright holder `SUB/WAVE contributors`.

Create these manifest-valid entry-point skeletons so validation is meaningful from the first slice:

```qml
// BarWidget.qml
import QtQuick
import qs.Commons

BarWidget {
  moduleName: "getsubwave.radio"
}
```

```qml
// StationPicker.qml
import QtQuick

Item {
  property var shell: null
  property var manifest: null
  function open(payloadJson) {}
  function close() {}
}
```

- [ ] **Step 7: Run the focused test and manifest validation**

Run:

```bash
node tests/model.test.mjs
omarchy plugin validate .
```

Expected: model tests print `StationModel tests passed`; manifest validation exits 0 with both entry-point skeletons present.

- [ ] **Step 8: Commit the model slice**

```bash
git add manifest.json StationModel.js tests/model.test.mjs tests/run LICENSE BarWidget.qml StationPicker.qml
git commit -m "feat: define SUB/WAVE station model"
```

---

### Task 2: Hardened Catalog and Now-Playing Client

**Files:**
- Create: `subwave-fetch`
- Create: `tests/fetch.test.sh`
- Modify: `tests/run`

**Interfaces:**
- Consumes: `subwave-fetch cache`, `subwave-fetch catalog`, or `subwave-fetch now-playing <origin>`.
- Produces from `cache`/`catalog`: a JSON array using the normalized station keys defined in Task 1, maximum 200 records.
- Produces from `now-playing`: `{online,station,dj,show,title,artist,album,coverUrl,listeners,error}` with strings capped at 512 bytes and `listeners` either a non-negative integer or `null`.
- Persists: `${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-subwave/catalog.json` and `state.json`, each at mode 0600 in a mode-0700 directory.

- [ ] **Step 1: Write failing fetch-helper tests with a fake `curl`**

Create `tests/fetch.test.sh`. Use `mktemp -d`, trap cleanup, and prepend a fake-bin directory to `PATH`. The fake `curl` copies `$FAKE_CURL_BODY` to the output path parsed after `--output`, or exits `$FAKE_CURL_EXIT`. Cover these exact assertions:

```bash
export XDG_DATA_HOME="$tmp/data"
export XDG_RUNTIME_DIR="$tmp/runtime"

FAKE_CURL_BODY="$tmp/catalog.json" "$root/subwave-fetch" catalog >"$tmp/out.json"
jq -e 'length == 2 and .[0].slug == "featured" and .[1].url == "https://radio.example"' "$tmp/out.json"
test "$(stat -c %a "$XDG_DATA_HOME/omarchy-subwave/catalog.json")" = 600

FAKE_CURL_EXIT=22 "$root/subwave-fetch" catalog >"$tmp/cached.json"
cmp "$tmp/out.json" "$tmp/cached.json"

FAKE_CURL_BODY="$tmp/now.json" "$root/subwave-fetch" now-playing https://radio.example >"$tmp/now-out.json"
jq -e '.online == true and .title == "Track" and .artist == "Artist" and .coverUrl == "https://radio.example/api/cover/abc"' "$tmp/now-out.json"

! "$root/subwave-fetch" now-playing 'https://u:p@radio.example'
```

Also create an 1,048,577-byte response and assert `catalog` fails without replacing the valid cache.

- [ ] **Step 2: Run the fetch tests and verify the helper is missing**

Run: `bash tests/fetch.test.sh`

Expected: FAIL with `subwave-fetch: No such file or directory`.

- [ ] **Step 3: Implement helper initialization, URL validation, and atomic writes**

Create executable `subwave-fetch` with `set -euo pipefail`, `umask 077`, a 1 MiB maximum response, a 200-record maximum, and:

```bash
data_root=${XDG_DATA_HOME:-$HOME/.local/share}
data_dir="$data_root/omarchy-subwave"
cache_file="$data_dir/catalog.json"
install -d -m 700 "$data_dir"

normalize_origin() {
  jq -nr --arg raw "$1" '
    try ($raw | capture("^(?<scheme>https?)://(?<host>[^/?#@[:space:]]+)(?<path>/[^?#]*)?$"))
    | "\(.scheme)://\(.host)" catch empty
  '
}

atomic_copy() {
  local source=$1 target=$2 temporary
  temporary=$(mktemp "$data_dir/.write.XXXXXX")
  install -m 600 "$source" "$temporary"
  mv -f "$temporary" "$target"
}
```

Keep every argument quoted and invoke `curl` as an argument array, never through `bash -c` or `eval`.

- [ ] **Step 4: Implement `cache` and `catalog`**

`cache` emits the valid cached array or `[]`. `catalog` downloads to a temporary file with:

```bash
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' \
  --connect-timeout 4 --max-time 10 \
  --max-filesize 1048576 \
  --user-agent "Omarchy SUB/WAVE/0.1.0" \
  --output "$download" \
  'https://www.getsubwave.com/stations.json'
```

After checking actual file size, transform with `jq` into the stable station shape, reject non-arrays, discard invalid name/origin rows, normalize paths to origins, deduplicate by URL, sort configured-independent rows using featured/name, cap to 200, atomically replace the cache, and emit it. If download or validation fails, emit a valid existing cache and exit 0; with no cache, emit `[]` and exit nonzero so QML can show a refresh error while remaining usable.

- [ ] **Step 5: Implement `now-playing`**

Validate the input origin, then request `${origin}/api/now-playing` with `--proto '=https,http'`, same-scheme redirects only, 3-second connect timeout, 6-second total timeout, and a 256 KiB cap. Transform the response with `jq --arg origin "$origin"` so `coverUrl` is constructed only from a `subsonic_id` matching `^[A-Za-z0-9_-]{1,64}$`. Read station name from `.dj.station`, DJ from `.dj.name`, show from `.activeShow.name`, and listener count from `.listeners.current` or a numeric `.listeners`. Treat `.streamOnline == false` as offline; absence remains online for older SUB/WAVE versions.

On any network/validation failure, emit:

```json
{"online":false,"station":"","dj":"","show":"","title":"","artist":"","album":"","coverUrl":"","listeners":null,"error":"Station unavailable"}
```

and exit nonzero.

- [ ] **Step 6: Run fetch tests and add them to the aggregate runner**

Run: `bash tests/fetch.test.sh`

Expected: all catalog, cache, size-limit, URL, and now-playing assertions pass.

Append `bash "$root/tests/fetch.test.sh"` to `tests/run`, then run `./tests/run`.

- [ ] **Step 7: Commit the fetch slice**

```bash
git add subwave-fetch tests/fetch.test.sh tests/run
git commit -m "feat: fetch SUB/WAVE station data safely"
```

---

### Task 3: Verified MPV Player Lifecycle

**Files:**
- Create: `subwave-player`
- Create: `tests/player.test.sh`
- Modify: `tests/run`

**Interfaces:**
- Consumes: `subwave-player play <origin> <station-name>`, `toggle`, `pause`, `stop`, `volume <0-100>`, and `status`.
- Produces on stdout and in `$XDG_RUNTIME_DIR/omarchy-subwave/status.json`: `{running,paused,volume,station:{name,url},error}`.
- Persists volume and last station in `${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-subwave/state.json`.
- Owns `$XDG_RUNTIME_DIR/omarchy-subwave/mpv.sock`, `player.pid`, and `mpv.log`.

- [ ] **Step 1: Write failing player tests with fake `mpv` and `socat`**

Create `tests/player.test.sh` with isolated XDG directories. The fake `mpv` records argv to `$FAKE_MPV_ARGS`, parses the `--input-ipc-server` argument, and executes `socat UNIX-LISTEN:"$socket",fork,reuseaddr SYSTEM:"$fake_bin/mpv-ipc"`. The `mpv-ipc` fixture reads one JSON request per line and answers with the same `request_id`, `.error:"success"`, and deterministic `pause`/`volume` data.

Assert:

```bash
"$root/subwave-player" status | jq -e '.running == false and .volume == 70'
! "$root/subwave-player" play 'file:///tmp/audio' 'Bad'
"$root/subwave-player" play 'https://radio.example/path' 'Example Radio' | jq -e '.running == true'
grep -F -- '--no-video' "$FAKE_MPV_ARGS"
grep -F -- '--input-ipc-server=' "$FAKE_MPV_ARGS"
grep -F -- 'https://radio.example/stream.mp3' "$FAKE_MPV_ARGS"
"$root/subwave-player" volume 95 | jq -e '.volume == 95'
! "$root/subwave-player" volume 101
"$root/subwave-player" toggle | jq -e '.running == true'
"$root/subwave-player" stop | jq -e '.running == false'
```

Write a PID record containing the test shell's PID but the wrong `/proc/<pid>/stat` start time; assert `stop` does not signal the shell and removes only stale runtime files.

- [ ] **Step 2: Run the player tests and verify the helper is missing**

Run: `bash tests/player.test.sh`

Expected: FAIL with `subwave-player: No such file or directory`.

- [ ] **Step 3: Implement directories, persistent state, and PID verification**

Create executable `subwave-player` using `set -euo pipefail`, `umask 077`, mode-0700 directories, and the same origin validator as `subwave-fetch`. Implement:

```bash
process_start_time() {
  local pid=$1
  [[ -r /proc/$pid/stat ]] || return 1
  awk '$3 != "Z" { print $22 }' "/proc/$pid/stat" 2>/dev/null
}

player_alive() {
  local pid expected actual
  [[ -s $pid_file ]] || return 1
  read -r pid expected <"$pid_file" || return 1
  [[ $pid =~ ^[0-9]+$ && $expected =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  actual=$(process_start_time "$pid") || return 1
  [[ $actual == "$expected" ]]
}
```

State normalization keeps only integer volume 0-100 and a credential-free HTTP(S) last-station origin/name. Malformed or oversized state is reported and left untouched; default volume is 70.

- [ ] **Step 4: Implement MPV IPC and status**

Use `socat -T 1 - UNIX-CONNECT:"$socket"` with a unique numeric `request_id`, cap responses at 64 KiB, and require `.error == "success"`. `status` queries `pause` and `volume`, validates the tracked process/socket, and atomically writes the stable status JSON. If identity/socket checks fail, it removes stale runtime files and reports `running:false` without signalling anything.

- [ ] **Step 5: Implement play, transport, volume, and stop**

`play` normalizes the origin and starts:

```bash
setsid mpv \
  --no-video \
  --force-window=no \
  --audio-display=no \
  --idle=yes \
  --cache-secs=20 \
  --demuxer-max-bytes=8MiB \
  --demuxer-max-back-bytes=2MiB \
  --network-timeout=30 \
  --volume="$volume" \
  --volume-max=100 \
  --input-ipc-server="$socket" \
  --no-terminal \
  --really-quiet \
  "$origin/stream.mp3"
```

Global `/etc/mpv/scripts/mpris.so` supplies MPRIS on Omarchy. Record PID plus process start time, wait up to 3 seconds for the socket, and tear down only the verified child if startup fails. Starting another station uses `loadfile` when a valid player exists and updates persisted station metadata.

`toggle` sends `cycle pause`; `pause` sends `set_property pause true`; `volume` validates an integer, sends `set_property volume`, and persists it; `stop` sends `quit`, waits two seconds, then TERM/KILLs only the verified process group if necessary.

- [ ] **Step 6: Run player and aggregate tests**

Run:

```bash
bash tests/player.test.sh
./tests/run
```

Expected: player lifecycle assertions pass, no test process is killed, and every prior test remains green.

- [ ] **Step 7: Commit the player slice**

```bash
git add subwave-player tests/player.test.sh tests/run
git commit -m "feat: add guarded SUB/WAVE playback"
```

---

### Task 4: Native Bar Widget and Station Overlay

**Files:**
- Modify: `BarWidget.qml`
- Modify: `StationPicker.qml`
- Modify: `tests/run`

**Interfaces:**
- Consumes: Task 1's `StationModel` functions, Task 2's three fetch commands, Task 3's player status/actions, and inline bar setting `stationUrl`.
- Produces: Omarchy overlay lifecycle `open(payloadJson)` and `close()`; bar widget id `getsubwave.radio`; payload `{stationUrl:<configured origin>}` when opening.
- Reads: `$XDG_RUNTIME_DIR/omarchy-subwave/status.json` with `FileView { atomicWrites: true }`.

- [ ] **Step 1: Replace manifest stubs with compiling entry-point skeletons**

`BarWidget.qml` must import `QtQuick`, `Quickshell`, `Quickshell.Io`, `qs.Commons`, and `qs.Ui`, extend `BarWidget`, set `moduleName: "getsubwave.radio"`, and provide a visible `WidgetButton`.

`StationPicker.qml` must import `QtQuick`, `QtQuick.Controls as QQC`, `Quickshell`, `Quickshell.Io`, `Quickshell.Wayland`, `qs.Commons`, `qs.Ui`, and `"StationModel.js" as StationModel`; extend `Item`; expose injected `omarchyPath`, `shell`, and `manifest`; and implement `open(payloadJson)`/`close()`.

- [ ] **Step 2: Run QML lint and fix only structural/API errors**

Run:

```bash
qmllint -I /usr/share/omarchy/shell BarWidget.qml StationPicker.qml
```

Expected: exit 0. Treat known upstream module warnings as warnings only; do not suppress genuine unknown-property, unknown-type, or syntax errors.

- [ ] **Step 3: Implement bar status parsing and actions**

Add `playerPath`, `fetchPath`, `statusPath`, and properties mirroring the player status. Parse at most 64 KiB, coerce volume to 0-100, and sanitize display text through `StationModel.singleLine`.

Use a `FileView` watcher plus an initial `Process` running `[playerPath, "status"]`. Implement gesture commands as argument arrays:

```qml
function playerAction(action, value) {
  if (actionProcess.running) return
  actionProcess.command = value === undefined
    ? [root.playerPath, action]
    : [root.playerPath, action, String(value)]
  actionProcess.running = true
}

function toggleOverlay() {
  var payload = JSON.stringify({ stationUrl: StationModel.normalizeOrigin(setting("stationUrl", "")) })
  Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "getsubwave.radio", payload])
}
```

Left click calls `toggleOverlay`, middle calls `toggle`, right calls `stop`, and wheel changes volume by five. Use a radio Nerd Font glyph, active/error state colors, vertical-safe sizing, a maximum 180-pixel scrolling label, and a plain-text tooltip.

- [ ] **Step 4: Implement selected-station now-playing refresh in the bar**

When status reports a station origin, a 5-second `Timer` invokes `[fetchPath,"now-playing",origin]`. Parse its stdout through `StdioCollector`, set title/artist/station/online state, and keep the last good title during a single transient failure while marking the tooltip offline. Stop polling when the player stops.

- [ ] **Step 5: Implement overlay lifecycle and catalog loading**

`open(payloadJson)` parses `stationUrl`, loads `[fetchPath,"cache"]` first, then starts `[fetchPath,"catalog"]`, merges via `StationModel.mergeConfigured`, populates a `ListModel`, resets selection to zero, sets `opened = true`, and focuses the search field with `Qt.callLater`.

Use `PanelWindow` with full-screen anchors, `WlrLayer.Overlay`, exclusive keyboard focus only while open, an Omarchy menu scrim, and a centered `BorderSurface`. Clicking the scrim or pressing Escape calls `dismiss()`, which also calls `shell.hide(manifest.id)`.

- [ ] **Step 6: Implement search, keyboard navigation, and station rows**

Use an Omarchy-themed text input and a `ListView`. On text changes, rebuild from `StationModel.searchStations(allStations, text)`. Up/Down wrap around; Enter calls `playSelected`; Escape clears a non-empty search first and closes on a second press.

Each row renders station name, configured/featured badge, location and genre, current track when known, and one of Checking/On air/Offline. Ensure all text uses elision or wrapping inside bounded row/card dimensions and never rich text.

- [ ] **Step 7: Implement bounded live-probe queue and playback handoff**

When opening or filtering, enqueue at most the first 24 visible origins. One reusable `Process` runs `[fetchPath,"now-playing",origin]` serially; completion updates a `liveByUrl` object and starts the next probe. Never create one long-running process per station. Refresh the playing station every five seconds and the visible set every thirty seconds while the overlay is open.

`playSelected()` runs `[playerPath,"play",station.url,station.name]`, marks the row as connecting, and on success updates playing state without automatically closing. A second activation of the playing station dismisses the overlay. Show concise catalog/playback errors inside the card rather than through a blocking dialog.

- [ ] **Step 8: Run static and aggregate validation**

Run:

```bash
qmllint -I /usr/share/omarchy/shell BarWidget.qml StationPicker.qml
omarchy plugin validate .
./tests/run
```

Expected: all commands exit 0.

- [ ] **Step 9: Commit the QML slice**

```bash
git add BarWidget.qml StationPicker.qml tests/run
git commit -m "feat: add native SUB/WAVE station picker"
```

---

### Task 5: Documentation and Continuous Validation

**Files:**
- Create: `README.md`
- Create: `.github/workflows/validate.yml`
- Modify: `manifest.json`

**Interfaces:**
- Consumes: all public controls, paths, commands, and limitations defined in Tasks 1-4.
- Produces: accurate user/operator documentation and a GitHub Actions gate for dependency-free tests.

- [ ] **Step 1: Write README installation and configuration sections**

Document:

```bash
omarchy plugin add https://github.com/getsubwave/omarchy-subwave.git --enable
omarchy bar set getsubwave.radio stationUrl https://radio.example.com
```

Explain that the station URL is a bare origin, the setting is optional, and the plugin always includes the public community directory. Include the left/middle/right/wheel/keyboard control table and the exact removal commands:

```bash
~/.config/omarchy/plugins/getsubwave.radio/subwave-player stop
omarchy plugin remove getsubwave.radio
```

- [ ] **Step 2: Document data, privacy, troubleshooting, and development**

State the directory and now-playing URLs contacted, the two XDG data locations, public-stream-only scope, lack of credential storage, MPV/MPRIS behavior, cache fallback, and diagnostics paths. Include:

```bash
./tests/run
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell BarWidget.qml StationPicker.qml
```

Do not claim a screenshot, marketplace listing, release, or live validation until Task 6 proves it.

- [ ] **Step 3: Add CI**

Create `.github/workflows/validate.yml` for pushes and pull requests. Use Ubuntu latest, checkout, install `jq` and `socat`, run `node tests/model.test.mjs`, and run shell tests with their fake dependencies. Add `jq -e` assertions for required manifest fields and `test -x` checks for `subwave-fetch`, `subwave-player`, and `tests/run`. Do not attempt QML lint on Ubuntu unless the Omarchy Quickshell modules are installed.

- [ ] **Step 4: Keep helper version reporting synchronized**

Have helpers obtain the user-agent version with `jq -r '.version' "$script_dir/manifest.json"`, falling back to `0.0.0` only when the manifest is unreadable. Add a fetch test asserting the fake curl arguments contain `Omarchy SUB/WAVE/0.1.0`.

- [ ] **Step 5: Run documentation-sensitive checks**

Run:

```bash
./tests/run
git diff --check
rg -n 'T[B]D|T[O]DO|F[I]XME|listener.*password|user:pass@' README.md manifest.json *.qml subwave-* tests .github
```

Expected: tests pass; the only credential-like text is documentation explicitly explaining rejection or test fixtures.

- [ ] **Step 6: Commit docs and CI**

```bash
git add README.md .github/workflows/validate.yml manifest.json subwave-fetch tests/fetch.test.sh
git commit -m "docs: document Omarchy SUB/WAVE plugin"
```

---

### Task 6: Live Omarchy Verification and Delivery

**Files:**
- Create: `preview.png`
- Modify if evidence requires: `BarWidget.qml`, `StationPicker.qml`, `subwave-fetch`, `subwave-player`, tests, or `README.md`

**Interfaces:**
- Consumes: the complete installable repository.
- Produces: local live evidence, preview asset, clean commits, and synchronized `origin/main`.

- [ ] **Step 1: Verify repository and remote state before installation**

Run:

```bash
git status --short
git remote -v
git fetch origin --prune
git log --oneline --decorate --graph --all -10
./tests/run
git diff --check
```

Expected: only intentional files are present, tests pass, and no unrelated remote commits need reconciliation.

- [ ] **Step 2: Install a recoverable local test checkout**

Record whether `getsubwave.radio` is already installed and its current bar entry before changing anything. If absent, clone the local repository into `~/.config/omarchy/plugins/getsubwave.radio` using `git clone /home/klair/Projects/omarchy-subwave ...`, run `omarchy-shell shell rescanPlugins`, and enable with `omarchy plugin enable getsubwave.radio`. If already present, do not overwrite it; validate through a separate temporary HOME instead or stop and report the conflict.

Configure the test station with:

```bash
omarchy bar set getsubwave.radio stationUrl https://www.getsubwave.com
```

Do not run `omarchy refresh shell` or modify `/usr/share/omarchy/`.

- [ ] **Step 3: Exercise live data and helper playback**

Verify:

```bash
~/.config/omarchy/plugins/getsubwave.radio/subwave-fetch catalog | jq 'length'
~/.config/omarchy/plugins/getsubwave.radio/subwave-fetch now-playing https://www.getsubwave.com | jq .
~/.config/omarchy/plugins/getsubwave.radio/subwave-player play https://www.getsubwave.com SUB/WAVE
playerctl --list-all | rg mpv
~/.config/omarchy/plugins/getsubwave.radio/subwave-player toggle
~/.config/omarchy/plugins/getsubwave.radio/subwave-player volume 65
~/.config/omarchy/plugins/getsubwave.radio/subwave-player stop
```

Expected: the catalog contains community stations, now-playing is bounded JSON, MPV appears over MPRIS, transport/volume succeed, and stop leaves no verified player process or socket.

- [ ] **Step 4: Exercise the live shell UI**

Open the overlay with `omarchy-shell shell toggle getsubwave.radio '{"stationUrl":"https://www.getsubwave.com"}'`. Verify configured-station deduplication, community rows, theme parity, search, Up/Down/Enter/Escape, playback state, tooltip, wheel volume, offline behavior with `https://127.0.0.1:9`, hot reload, and no errors in shell logs. Run `omarchy debug --no-sudo --print` only if diagnostics are required.

- [ ] **Step 5: Capture and add the preview**

With the populated overlay open, capture a clean screenshot using `omarchy capture screenshot` and crop it to a marketplace-friendly preview without exposing unrelated windows, notifications, hostnames, or secrets. Save it as `preview.png`, reference it near the top of `README.md`, and run `file preview.png` to confirm a valid PNG.

- [ ] **Step 6: Restore local user configuration**

Stop the player, disable/remove only the local test plugin if it was absent before testing, and restore the exact recorded bar entry/settings. Verify `omarchy plugin list --json` and the relevant `shell.json` entry match the pre-test state. Persistent test data under `~/.local/share/omarchy-subwave/` may be removed only if created by this test and did not exist beforehand.

- [ ] **Step 7: Re-run the full gate and commit evidence-driven fixes**

Run:

```bash
./tests/run
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell BarWidget.qml StationPicker.qml
git diff --check
git status --short
```

Commit the preview and any focused live fixes:

```bash
git add preview.png README.md BarWidget.qml StationPicker.qml subwave-fetch subwave-player tests
git commit -m "chore: finish Omarchy plugin validation"
```

Skip unchanged paths rather than using `git add -A`.

- [ ] **Step 8: Push and verify the public install path**

Confirm `git status` is clean, push `main` to `origin`, and compare local HEAD with `git ls-remote origin refs/heads/main`. Then remove any remaining local test checkout and perform the real public install:

```bash
omarchy plugin add https://github.com/getsubwave/omarchy-subwave.git --enable
```

Verify `omarchy plugin validate ~/.config/omarchy/plugins/getsubwave.radio`, configure the station URL, open the overlay once, and stop playback. Leave the plugin installed only if that matches the user's current request; otherwise remove it after proving the public path.
