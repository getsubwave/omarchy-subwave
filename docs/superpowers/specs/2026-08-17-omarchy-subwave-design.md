# Omarchy SUB/WAVE Plugin Design

## Goal

Build a native Omarchy shell plugin for listening to a configured self-hosted
SUB/WAVE station and discovering every public station in the SUB/WAVE community
directory. The plugin should feel like part of the Omarchy bar, keep playback
available through Omarchy's existing media controls, and require no changes to
the SUB/WAVE server.

## Scope

Version 1 includes:

- A theme-aware Omarchy bar widget.
- A searchable, keyboard-navigable station overlay.
- One configurable self-hosted station shown first as **My station**.
- The public SUB/WAVE community station directory.
- Live now-playing and online/offline status.
- MP3 playback through a dedicated `mpv` process with MPRIS integration.
- Persistent last-station and volume state.
- Cached community data for temporary network failures.

Version 1 does not include:

- A globe or geographic map.
- Listener-authenticated/private streams.
- Listener requests or operator/admin controls.
- Editing the community catalog.
- A second media-control implementation that competes with `omarchy.media`.

## Plugin Contract

The repository root is directly installable with:

```bash
omarchy plugin add https://github.com/getsubwave/omarchy-subwave.git --enable
```

The manifest uses schema version 1, plugin id `getsubwave.radio`, and the
`bar-widget` and `overlay` kinds. The overlay remains loaded between openings so
its directory, selection, and live state remain warm.

The bar widget defaults to the left section and allows only one instance. The
self-hosted origin is an inline widget setting named `stationUrl`, configured
with:

```bash
omarchy bar set getsubwave.radio stationUrl https://radio.example.com
```

The URL is optional. When it is absent, the plugin still exposes every community
station without inventing a local default.

## User Experience

### Bar widget

The bar displays a radio glyph and, when space permits, the current track as
`Title · Artist`. It uses Omarchy theme roles and adapts to horizontal and
vertical bars.

- Left click toggles the station overlay.
- Middle click toggles play/pause for the plugin's player.
- Right click stops the plugin's player.
- The mouse wheel adjusts the plugin player's volume in five-point increments.
- The tooltip names the station, track, playback state, and volume.

The widget indicates on-air, paused, offline, and error states without
disappearing when a station is unavailable.

### Station overlay

The overlay opens focused on a search field and supports arrow keys, Enter, and
Escape. The configured self-hosted station appears first as **My station**,
unless its normalized origin already matches a catalog entry; in that case the
catalog entry is promoted and marked as the user's station rather than
duplicated.

Community stations are fetched from:

```text
https://www.getsubwave.com/stations.json
```

Search matches station name, genre, location, country, operator, and
description. Featured stations sort first, followed by station name, while the
configured station always remains first.

Each result shows its name, location/genre when present, and live status. Live
probes are bounded and lazy: visible stations are checked when the overlay opens,
and the selected/playing station is refreshed more frequently. Selecting a
station starts playback and keeps the overlay open long enough to show success
or a useful failure; a second action or Escape closes it.

## Components

### `manifest.json`

Declares plugin metadata, entry points, bar placement, and the two supported
kinds.

### `BarWidget.qml`

Owns the compact bar presentation and user gestures. It reads the atomic player
status file and invokes the player helper for transport and volume actions. It
summons or hides the overlay through Omarchy shell IPC.

### `StationPicker.qml`

Owns overlay lifecycle, search, selection, station cards, keyboard interaction,
catalog refresh, and live probes. It delegates parsing and list derivation to a
pure JavaScript module and all process/network work to helper commands.

### `StationModel.js`

Contains pure, testable functions for:

- Origin normalization and validation.
- Catalog record normalization and limits.
- Configured-station insertion/deduplication.
- Featured/name ordering.
- Search filtering.
- Safe single-line display text.

### `subwave-fetch`

A Bash helper using Omarchy-standard tools (`curl`, `jq`, and coreutils). It
fetches the directory or a station's `/api/now-playing`, applies connection and
total timeouts, caps response sizes before parsing, rejects malformed records,
and writes cache files atomically. Its output is a small stable JSON contract for
QML rather than arbitrary upstream JSON.

### `subwave-player`

A Bash helper that owns one `mpv` process, its IPC socket, PID identity, status
file, and volume. Commands are `play`, `toggle`, `pause`, `stop`, `volume`, and
`status`. It launches audio-only playback for the normalized station origin's
`/stream.mp3`, enables the installed `mpv-mpris` integration, and writes status
atomically under `$XDG_RUNTIME_DIR/omarchy-subwave/`.

The helper validates both the tracked PID and its process start time before
signalling it. It never kills an unverified process.

## Data Flow

1. Enabling the plugin creates its bar entry; no network work occurs during
   installation.
2. Loading the widget asks `subwave-player status` to establish current state.
3. Opening the overlay loads the last good catalog immediately, then refreshes
   `stations.json` in the background.
4. The configured station URL is normalized to an HTTP(S) origin and merged into
   the directory.
5. Live probes request `<origin>/api/now-playing` and emit only the fields used by
   the UI: station/DJ identity, track metadata, listener count, stream state, and
   artwork URL.
6. Selecting a station gives the normalized origin and display metadata to
   `subwave-player`, which starts `<origin>/stream.mp3`.
7. Player status changes are written atomically; QML watches the status file and
   updates both entry points.
8. `mpv-mpris` exposes the player to Omarchy's existing `omarchy.media` service.

## State and Configuration

Runtime-only files live in:

```text
$XDG_RUNTIME_DIR/omarchy-subwave/
```

They include the MPV socket, verified PID record, current station handoff, player
status, and logs.

Persistent non-secret data lives in:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-subwave/
```

It contains the last-good directory cache and a bounded state document with the
last station and volume. Files are created with user-only permissions. Malformed
or oversized state is reported and left untouched rather than overwritten.

The configured self-hosted origin stays in Omarchy's inline bar settings. No
credentials are accepted or persisted in version 1.

## Security and Failure Handling

Omarchy plugins execute unsandboxed inside the shell, so remote data is treated
as untrusted:

- Only `http` and `https` station origins are accepted.
- URLs containing credentials, control characters, fragments, or unsupported
  schemes are rejected.
- Catalog and now-playing responses have byte, record, field-length, redirect,
  connect-time, and total-time limits.
- Remote strings are displayed as plain text and never interpolated into shell
  commands.
- Helper commands pass data through files or positional arguments after strict
  validation; they do not evaluate remote content.
- State and status writes use temporary files followed by atomic rename.
- Playback is limited to the selected origin's fixed `/stream.mp3` path.
- A failed catalog refresh retains the last-good cache. With no cache, the
  configured station remains usable.
- A failed station probe marks only that station offline.
- A failed playback attempt leaves the UI responsive, records a concise error,
  and does not retry aggressively.

Version 1 deliberately excludes listener-authenticated stations because placing
a shared listener secret in `shell.json`, process arguments, or ordinary cache
files would expose it. Private-stream support requires a separate secret-storage
design.

## Testing and Validation

Pure JavaScript tests cover catalog normalization, hostile/malformed data,
deduplication, sorting, searching, and URL rules.

Shell tests use temporary runtime/data directories and fake `curl`, `mpv`, and
IPC responses to cover:

- Size and timeout failures.
- Atomic cache/status writes.
- Player lifecycle and stale PID protection.
- Volume bounds.
- Offline and malformed station responses.

Release validation runs:

```bash
./tests/run
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell BarWidget.qml StationPicker.qml
```

Finally, the repository is installed locally with `omarchy plugin add` or copied
to a temporary user-plugin directory, enabled, and exercised against the current
Omarchy shell. Live verification covers catalog loading, configured-station
deduplication, search and keyboard navigation, playback, MPRIS controls, volume,
offline degradation, and hot reload. User shell configuration is not reset or
overwritten during testing.

## Delivery

The initial repository ships the plugin sources, tests, MIT license, screenshot
or preview asset, and a README covering installation, configuration, controls,
privacy, removal, troubleshooting, and development commands. The first release
is tagged only after the install command works against the public GitHub
repository.
