// Run: node tests/model.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "SavannaModel.js"), "utf8").replace(".pragma library", "")
const ctx = { module: { exports: {} } }
vm.runInNewContext(src, ctx)
const M = ctx.module.exports

// 3 columns x 2 rows = 6 per page; 14 items -> pages of 6, 6, 2
const C = 3, R = 2, N = 14
assert.strictEqual(M.pageCount(N, C, R), 3)
assert.strictEqual(M.pageCount(0, C, R), 1)
assert.strictEqual(M.pageOf(7, C, R), 1)

// right inside a row, then across the page edge, same row
assert.strictEqual(M.move(0, "right", N, C, R), 1)
assert.strictEqual(M.move(2, "right", N, C, R), 6)      // page0 row0 end -> page1 row0 col0
assert.strictEqual(M.move(5, "right", N, C, R), 9)      // page0 row1 end -> page1 row1 col0
assert.strictEqual(M.move(11, "right", N, C, R), 13)    // page1 row1 end -> page2 row1 missing -> last item
// left across the edge
assert.strictEqual(M.move(6, "left", N, C, R), 2)
assert.strictEqual(M.move(9, "left", N, C, R), 5)
assert.strictEqual(M.move(0, "left", N, C, R), 0)       // nowhere to go
// up/down stay on the page
assert.strictEqual(M.move(1, "down", N, C, R), 4)
assert.strictEqual(M.move(4, "down", N, C, R), 4)       // last row of the page
assert.strictEqual(M.move(4, "up", N, C, R), 1)
assert.strictEqual(M.move(12, "down", N, C, R), 12)     // no item below
// paging
assert.strictEqual(M.move(4, "nextPage", N, C, R), 10)
assert.strictEqual(M.move(10, "nextPage", N, C, R), 13) // page2 has only 2 items -> clamp
assert.strictEqual(M.move(13, "prevPage", N, C, R), 7)
assert.strictEqual(M.move(5, "end", N, C, R), 13)
assert.strictEqual(M.move(0, "right", 0, C, R), 0)
// vertical paging: pages stacked, up/down cross pages on the same column
assert.strictEqual(M.move(4, "down", N, C, R, true), 7)    // page0 last row col1 -> page1 first row col1
assert.strictEqual(M.move(11, "down", N, C, R, true), 13)  // page1 -> page2 col2 missing -> last item
assert.strictEqual(M.move(7, "up", N, C, R, true), 4)      // page1 first row col1 -> page0 last row col1
assert.strictEqual(M.move(1, "up", N, C, R, true), 1)      // nowhere to go
assert.strictEqual(M.move(2, "right", N, C, R, true), 2)   // left/right stay on the page
assert.strictEqual(M.move(6, "left", N, C, R, true), 6)
assert.strictEqual(M.move(4, "nextPage", N, C, R, true), 10)
// rows -> items
assert.deepStrictEqual(JSON.parse(JSON.stringify(M.itemsFromRows([{ entry: { id: "a", name: "A", icon: "x" } }, { entry: null }]))),
  [{ id: "a", name: "A", icon: "x" }])
console.log("ok")

// fallback search
const entries = [
  { id: "firefox", name: "Firefox", genericName: "Web Browser", icon: "firefox" },
  { id: "org.gnome.Nautilus", name: "Files", keywords: ["folder", "explorer"] },
  { id: "hidden", name: "Hidden app" },
  { id: "nd", name: "No display", noDisplay: true },
  { id: "alacritty", name: "Alacritty" },
]
const names = (q, h) => M.itemsFromEntries(entries, q, h || {}).map(i => i.name).join(",")
assert.strictEqual(names(""), "Alacritty,Files,Firefox,Hidden app")
assert.strictEqual(names("", M.parseHides("hidden.desktop\n# comment\n")), "Alacritty,Files,Firefox")
assert.strictEqual(names("fi"), "Files,Firefox")
assert.strictEqual(names("browser"), "Firefox")
assert.strictEqual(names("folder"), "Files")
assert.strictEqual(names("zzz"), "")
console.log("ok fallback")

// word-start matching, on the entries that used to pollute "fi"
const real = [
  { id: "org.gnome.Nautilus", name: "Files", comment: "Access and organize files", keywords: ["folder", "manager", "filesystem", "nautilus"] },
  { id: "firefox", name: "Firefox", genericName: "Web Browser" },
  { id: "strata", name: "Strata", genericName: "File Manager", keywords: ["files", "folders", "browser"] },
  { id: "libreoffice-writer", name: "LibreOffice Writer", keywords: ["Text", "Letter", "Fax", "Document"] },
  { id: "libreoffice-startcenter", name: "LibreOffice", genericName: "Office" },
  { id: "voxtype-configure", name: "Voxtype Configuration", comment: "Configure voxtype dictation settings" },
  { id: "code", name: "Visual Studio Code", comment: "Code Editing. Redefined." },
  { id: "wireshark", name: "Wireshark", comment: "Network traffic analyzer" },
  { id: "nvim", name: "Neovim", comment: "Edit text files" },
  { id: "org.gnome.Settings", name: "Réglages", keywords: ["écran", "son"] },
]
const find = q => M.itemsFromEntries(real, q, {}).map(i => i.name).join(",")
assert.strictEqual(find("fi"), "Files,Firefox,Strata")             // no Office / Configuration / Redefined / traffic
assert.strictEqual(find("fil"), "Files,Strata")                    // "files" in Neovim's comment needs 4+ letters
assert.strictEqual(find("file"), "Files,Strata,Neovim")
assert.strictEqual(find("vsc"), "Visual Studio Code")              // initials
assert.strictEqual(find("code"), "Visual Studio Code")
assert.strictEqual(find("office"), "LibreOffice,LibreOffice Writer") // camelCase word, shortest name first
assert.strictEqual(find("lo w"), "LibreOffice Writer")             // every term must match
assert.strictEqual(find("fox"), "Firefox")                         // inside the name, 3+ letters
assert.strictEqual(find("con"), "Voxtype Configuration")
assert.strictEqual(find("ecran"), "Réglages")                      // accents ignored
assert.strictEqual(find("reg"), "Réglages")
assert.strictEqual(find("Fi"), "Files,Firefox,Strata")
console.log("ok search")
