var MAX_STATIONS = 200
var MAX_FIELD = 512

function singleLine(value, limit) {
  var cap = Math.max(0, Math.min(MAX_FIELD, Number(limit) || MAX_FIELD))
  return String(value || "").replace(/[\r\n\t\u0000-\u001f\u007f]+/g, " ").trim().slice(0, cap)
}

function normalizeOrigin(value) {
  var raw = String(value || "").trim()
  if (!raw || /[\u0000-\u001f\u007f]/.test(raw)) return ""
  var matched = raw.match(/^(https?):\/\/([^\/@?#\s]+)(?:\/[^?#]*)?\/?$/i)
  if (!matched) return ""
  return matched[1].toLowerCase() + "://" + matched[2]
}

function fallbackSlug(name) {
  return singleLine(name, 80).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 49)
}

function normalizeStation(value) {
  if (!value || typeof value !== "object") return null
  var name = singleLine(value.name, 160)
  var url = normalizeOrigin(value.url)
  if (!name || !url) return null
  return {
    slug: singleLine(value.slug, 49) || fallbackSlug(name),
    name: name,
    url: url,
    location: singleLine(value.location, 160),
    country: singleLine(value.country, 100),
    operator: singleLine(value.operator, 100),
    genre: singleLine(value.genre, 160),
    description: singleLine(value.description, MAX_FIELD),
    featured: value.featured === true,
    submitted: singleLine(value.submitted, 32),
    isConfigured: value.isConfigured === true
  }
}

function compareStations(a, b) {
  if (a.featured !== b.featured) return a.featured ? -1 : 1
  var left = a.name.toLowerCase()
  var right = b.name.toLowerCase()
  return left < right ? -1 : (left > right ? 1 : 0)
}

function normalizeCatalog(value) {
  var source = Array.isArray(value) ? value : []
  var seen = ({})
  var rows = []
  for (var i = 0; i < source.length; i++) {
    var station = normalizeStation(source[i])
    if (!station || seen[station.url]) continue
    seen[station.url] = true
    rows.push(station)
  }
  rows.sort(compareStations)
  return rows.slice(0, MAX_STATIONS)
}

function mergeConfigured(stations, stationUrl) {
  var rows = normalizeCatalog(stations)
  var origin = normalizeOrigin(stationUrl)
  if (!origin) return rows
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].url !== origin) continue
    var matched = Object.assign({}, rows[i], { isConfigured: true })
    rows.splice(i, 1)
    rows.unshift(matched)
    return rows
  }
  rows.unshift({
    slug: "__configured",
    name: "My station",
    url: origin,
    location: "",
    country: "",
    operator: "",
    genre: "",
    description: "Your configured SUB/WAVE station",
    featured: false,
    submitted: "",
    isConfigured: true
  })
  return rows.slice(0, MAX_STATIONS)
}

function searchStations(stations, query) {
  var rows = Array.isArray(stations) ? stations : []
  var needle = singleLine(query, 160).toLowerCase()
  if (!needle) return rows.slice()
  return rows.filter(function(station) {
    return [station.name, station.genre, station.location, station.country,
      station.operator, station.description].join(" ").toLowerCase().indexOf(needle) !== -1
  })
}
