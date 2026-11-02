.pragma library

// Pure grid/paging logic for Savanna, kept free of QML so it can be tested
// with node (see tests/model.test.js).

function perPage(columns, rows) {
  return Math.max(1, columns) * Math.max(1, rows)
}

function pageCount(count, columns, rows) {
  return Math.max(1, Math.ceil(count / perPage(columns, rows)))
}

function pageOf(index, columns, rows) {
  return Math.floor(Math.max(0, index) / perPage(columns, rows))
}

// Turns AppLibrary.sortedEntries() rows into plain grid items.
function itemsFromRows(rows) {
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var entry = rows[i] && rows[i].entry
    if (!entry || !entry.id) continue
    out.push({ id: String(entry.id), name: String(entry.name || entry.id), icon: String(entry.icon || "") })
  }
  return out
}

// Fallback search used when the host app-library facade is unavailable.
// `entries` are Quickshell DesktopEntry objects; `hidden` maps ids to true.
//
// Alfred-style matching: a typed term must match the start of a word, never
// the middle of one ("fi" must not find "Office" or "Configuration"). Each
// term takes its best match, by decreasing weight:
//   name word > name initials ("vsc") > id word > inside the name (3+ chars)
//   > generic name / keywords word > description word (4+ chars).
// Every term has to match somewhere; accents and case are ignored.

function fold(text) {
  var s = String(text || "")
  if (s.normalize) s = s.normalize("NFD").replace(/[̀-ͯ]/g, "")
  return s.toLowerCase()
}

// "LibreOffice Calc" -> ["libre", "office", "calc"]; "org.gnome.Nautilus" ->
// ["org", "gnome", "nautilus"].
function words(text) {
  return fold(String(text || "").replace(/([a-z])([A-Z])/g, "$1 $2"))
    .split(/[^a-z0-9]+/).filter(function(w) { return w.length > 0 })
}

function anyPrefix(list, term) {
  for (var i = 0; i < list.length; i++) if (list[i].indexOf(term) === 0) return i
  return -1
}

function searchFields(entry) {
  var nameWords = words(entry.name)
  var keywords = (entry.keywords && entry.keywords.join) ? entry.keywords.join(" ") : ""
  return {
    name: fold(entry.name),
    nameWords: nameWords,
    initials: nameWords.map(function(w) { return w.charAt(0) }).join(""),
    idWords: words(entry.id),
    tagWords: words(String(entry.genericName || "") + " " + keywords),
    commentWords: words(entry.comment)
  }
}

function scoreTerm(f, term) {
  var i = anyPrefix(f.nameWords, term)
  if (i >= 0) return i === 0 ? 1200 : 1000
  if (term.length >= 2 && f.initials.indexOf(term) === 0) return 900
  if (anyPrefix(f.idWords, term) >= 0) return 600
  if (term.length >= 3 && f.name.indexOf(term) >= 0) return 500
  if (anyPrefix(f.tagWords, term) >= 0) return 300
  if (term.length >= 4 && anyPrefix(f.commentWords, term) >= 0) return 100
  return -1
}

function scoreEntry(entry, q) {
  if (!q) return 0
  var f = searchFields(entry)
  var terms = q.split(/\s+/)
  var score = 0
  for (var t = 0; t < terms.length; t++) {
    if (!terms[t]) continue
    var s = scoreTerm(f, terms[t])
    if (s < 0) return -1
    score += s
  }
  // The whole query starting the name beats everything; shorter names first.
  if (f.name.indexOf(q) === 0) score += 5000
  return score - f.name.length
}

function itemsFromEntries(entries, query, hidden) {
  var q = fold(query).trim()
  var rows = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    if (!e || e.noDisplay || !e.id || !e.name) continue
    if (hidden && hidden[String(e.id)] === true) continue
    var score = scoreEntry(e, q)
    if (score < 0) continue
    rows.push({ score: score, key: String(e.name).toLowerCase(), item: { id: String(e.id), name: String(e.name), icon: String(e.icon || "") } })
  }
  rows.sort(function(a, b) {
    if (q && a.score !== b.score) return b.score - a.score
    return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0)
  })
  return rows.map(function(r) { return r.item })
}

function parseHides(text) {
  var out = {}
  String(text || "").split(/\n/).forEach(function(line) {
    var id = line.trim()
    if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
    if (id && id.charAt(0) !== "#") out[id] = true
  })
  return out
}

function slice(items, page, columns, rows) {
  var n = perPage(columns, rows)
  return items.slice(page * n, page * n + n)
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// Moves the selection like Launchpad: arrows stay on the current page, and
// stepping past its left/right edge lands on the neighbouring page, same row.
// With vertical paging, pages are stacked instead: stepping past the
// bottom/top edge lands on the next/previous page, same column.
// Returns the new global index (or the old one when there is nowhere to go).
function move(index, direction, count, columns, rows, vertical) {
  if (count <= 0) return 0
  var n = perPage(columns, rows)
  var last = count - 1
  index = clamp(index, 0, last)

  var page = Math.floor(index / n)
  var local = index - page * n
  var row = Math.floor(local / columns)
  var col = local % columns
  var pages = pageCount(count, columns, rows)
  var target = index

  if (direction === "right") {
    if (col < columns - 1 && index < last) target = index + 1
    else if (!vertical && page < pages - 1) target = (page + 1) * n + row * columns
  } else if (direction === "left") {
    if (col > 0) target = index - 1
    else if (!vertical && page > 0) target = (page - 1) * n + row * columns + columns - 1
  } else if (direction === "down") {
    if (row < rows - 1 && index + columns <= last) target = index + columns
    else if (vertical && page < pages - 1) target = (page + 1) * n + col
  } else if (direction === "up") {
    if (row > 0) target = index - columns
    else if (vertical && page > 0) target = (page - 1) * n + (rows - 1) * columns + col
  } else if (direction === "nextPage") {
    if (page < pages - 1) target = (page + 1) * n + local
  } else if (direction === "prevPage") {
    if (page > 0) target = (page - 1) * n + local
  } else if (direction === "home") {
    target = 0
  } else if (direction === "end") {
    target = last
  }

  return clamp(target, 0, last)
}

if (typeof module !== "undefined") {
  module.exports = { itemsFromEntries: itemsFromEntries, parseHides: parseHides, perPage: perPage, pageCount: pageCount, pageOf: pageOf, itemsFromRows: itemsFromRows, slice: slice, move: move }
}
