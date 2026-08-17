import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"
import { fileURLToPath } from "node:url"

const testDir = path.dirname(fileURLToPath(import.meta.url))
const source = fs.readFileSync(path.join(testDir, "..", "StationModel.js"), "utf8")
// QML's JavaScript engine does not provide the browser/Node URL constructor.
const model = { Array, Boolean, JSON, Math, Number, Object, RegExp, String }
vm.createContext(model)
vm.runInContext(source, model)

assert.equal(model.normalizeOrigin(" https://radio.example.com/path/ "), "https://radio.example.com")
assert.equal(model.normalizeOrigin("http://radio.example.com:7700"), "http://radio.example.com:7700")
assert.equal(model.normalizeOrigin("https://user:pass@radio.example.com"), "")
assert.equal(model.normalizeOrigin("file:///tmp/stream"), "")
assert.equal(model.normalizeOrigin("https://radio.example.com/#secret"), "")
assert.equal(model.normalizeOrigin("https://radio.example.com/\nnext"), "")

assert.equal(typeof model.configuredStationUpdate, "function")
assert.deepEqual(
  JSON.parse(JSON.stringify(model.configuredStationUpdate(" https://radio.example.com/listen "))),
  {
    ok: true,
    url: "https://radio.example.com",
    command: ["omarchy", "bar", "set", "getsubwave.radio", "stationUrl", "https://radio.example.com"]
  }
)
assert.deepEqual(
  JSON.parse(JSON.stringify(model.configuredStationUpdate(""))),
  {
    ok: true,
    url: "",
    command: ["omarchy", "bar", "set", "getsubwave.radio", "stationUrl", ""]
  }
)
assert.equal(model.configuredStationUpdate("https://user:pass@radio.example.com").ok, false)
assert.equal(model.configuredStationUpdate("file:///tmp/stream").ok, false)

assert.equal(typeof model.barTooltip, "function")
assert.equal(model.barTooltip({
  running: true,
  paused: false,
  stationName: "ChillWave",
  trackTitle: "Wish We Had History",
  trackArtist: "Bexy",
  volume: 65
}), "Wish We Had History — Bexy\nChillWave · Playing · 65%")
assert.equal(model.barTooltip({
  running: false,
  stationName: "SUB/WAVE",
  volume: 70
}), "SUB/WAVE\nOpen · 70%")
assert.equal(model.barTooltip({
  running: true,
  paused: true,
  stationName: "Chill\nWave",
  trackTitle: "Track\nName",
  volume: 101
}), "Track Name\nChill Wave · Paused · 100%")

assert.equal(typeof model.webPlayerCommand, "function")
assert.deepEqual(
  Array.from(model.webPlayerCommand("https://radio.example.com/listen")),
  ["omarchy", "launch", "browser", "https://radio.example.com"]
)
assert.deepEqual(Array.from(model.webPlayerCommand("https://user:pass@radio.example.com")), [])
assert.deepEqual(Array.from(model.webPlayerCommand("javascript:alert(1)")), [])

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

const reconfigured = model.mergeConfigured(synthetic, "https://featured.example")
assert.equal(reconfigured.length, 2)
assert.equal(reconfigured[0].url, "https://featured.example")
assert.equal(reconfigured.filter(row => row.isConfigured).length, 1)
const cleared = model.mergeConfigured(reconfigured, "")
assert.equal(cleared.length, 2)
assert.equal(cleared.filter(row => row.isConfigured).length, 0)

assert.deepEqual(
  Array.from(model.searchStations(synthetic, "jazz"), row => row.slug),
  ["zeta"]
)
assert.equal(model.searchStations(synthetic, "").length, 3)
assert.equal(model.normalizeCatalog(Array.from({ length: 250 }, (_, i) => ({
  slug: `s-${i}`, name: `Station ${i}`, url: `https://s-${i}.example`
}))).length, 200)

assert.equal(model.singleLine(" a\n\tb ", 20), "a b")
assert.equal(model.singleLine("abcdef", 3), "abc")

console.log("StationModel tests passed")
