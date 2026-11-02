# Savanna

A fullscreen app launcher for [Omarchy](https://omarchy.org). It shows every
application as a grid of icons, page after page, and filters it as you type.
It follows your Omarchy theme: colours and wallpaper.

Savanna is an Omarchy shell plugin (Omarchy 4).

## Install

```sh
omarchy plugin add https://github.com/XNinety9/savanna --enable
```

This installs Savanna into `~/.config/omarchy/plugins/x99.savanna/` and puts
its button on the left of the bar. If the button does not show up, restart
the shell with `omarchy-restart-shell`.

To open it with SUPER+A, add this line to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + A", "Savanna", "omarchy-shell shell toggle x99.savanna '{}'")
```

To open it like Launchpad, with a four-finger pinch (and close it by
spreading the fingers), add this to `~/.config/hypr/input.lua`:

```lua
hl.gesture({ fingers = 4, direction = "pinchout", action = function()
  hl.exec_cmd("omarchy-shell shell summon x99.savanna '{}'")
end })
hl.gesture({ fingers = 4, direction = "pinchin", action = function()
  hl.exec_cmd("omarchy-shell shell call x99.savanna dismiss x")
end })
```

To install by hand instead, clone the repository to
`~/.config/omarchy/plugins/x99.savanna/` (a real folder, not a symlink), run
`omarchy-restart-shell`, then `omarchy plugin enable x99.savanna`.

To update later: `omarchy plugin update x99.savanna`.

## Use

Open Savanna from its bar button, with your shortcut, or with:

```sh
omarchy-shell shell toggle x99.savanna '{}'
```

| Action          | How                                                        |
|-----------------|------------------------------------------------------------|
| Search          | Start typing. Matches the start of words and initials: `fi` → Files, Firefox; `vsc` → Visual Studio Code |
| Launch          | Click an icon, or press Enter (the first result when searching) |
| Move around     | Arrow keys                                                 |
| Change page     | Two-finger swipe, mouse wheel, click-and-drag, Page Up / Page Down, or click a page dot |
| Clear / close   | Escape clears the search, then closes. A click on empty space also closes |
| Uninstall       | Long-press an icon: icons wiggle, click the ✕. Or select an app and press Delete. Escape or a click on empty space leaves this mode |

Apps hidden in Omarchy's own launcher (`launcher.hides`) are hidden here too.

Uninstalling always asks first, and the confirmation says what goes: for a
package, pacman's dry run, including the dependencies only it needed. Savanna
stays open: the icon vanishes and the others slide into place. Packages ask
for your password in Omarchy's own prompt; web apps, terminal apps and
Flatpaks need none. Apps Omarchy relies on (Files, Disks, Document Viewer, the
browser…) have no ✕: Savanna only removes Omarchy's own apps when Omarchy
lists them as optional preinstalls.

## Configure

Savanna is configured like other Omarchy shell plugins. Changes apply as soon
as the file is saved; there is no need to restart.

### Layout and effects

Set these with `omarchy bar set`, from the shell settings panel, or directly
on the `x99.savanna` entry in `~/.config/omarchy/shell.json`:

```sh
omarchy bar set x99.savanna size Centered
omarchy bar set x99.savanna columns 6
omarchy bar set x99.savanna showLabels false --json
```

| Setting       | Values                                   | Default      | What it does |
|---------------|------------------------------------------|--------------|--------------|
| `size`        | `Fullscreen`, `Centered`                 | `Fullscreen` | Fullscreen, or a bordered card in the middle of the screen |
| `width`       | 0.3 – 1                                  | `0.7`        | Card width, as a fraction of the screen |
| `height`      | 0.3 – 1                                  | `0.75`       | Card height |
| `borderWidth` | 0 – 12 px                                | `2`          | Card border |
| `radius`      | 0 – 64 px                                | your Hyprland rounding | Card corners |
| `columns`     | 3 – 12                                   | `7`          | Icons per row |
| `rows`        | 2 – 8                                    | `5`          | Rows per page |
| `paging`      | `Horizontal`, `Vertical`                 | `Horizontal` | Pages side by side, or stacked (dots on the right) |
| `iconSize`    | 32 – 192 px                              | `96`         | Largest icon size. Icons shrink to fit dense grids |
| `showLabels`  | `true`, `false`                          | `true`       | App names under the icons |
| `backdrop`    | `Wallpaper`, `Glass`, `Desktop`, `Solid` | `Wallpaper`  | What is behind the grid (see below) |
| `blur`        | 0 – 1                                    | `1`          | Wallpaper blur (0 = sharp) |
| `dim`         | 0 – 1                                    | `0.45`       | Strength of the theme tint |
| `glow`        | `true`, `false`                          | `true`       | Accent glow above the search field |
| `shadows`     | `true`, `false`                          | `true`       | Icon shadows |
| `animations`  | `Full`, `Subtle`, `None`                 | `Full`       | Ripple and springy hovers / plain fades / instant |

Backdrops:

- **Wallpaper**: your current wallpaper, blurred.
- **Glass**: frosted glass over your windows. It needs the Hyprland rule below.
- **Desktop**: your windows stay visible under a tint.
- **Solid**: the theme background colour.

### Frosted glass

Add these two rules to your Hyprland config, for example in
`~/.config/hypr/looknfeel.lua`. The blur strength comes from your
`decoration.blur` settings.

```lua
hl.layer_rule({ name = "savanna-no-anim", match = { namespace = "^savanna(-glass)?$" }, no_anim = true, animation = "none" })
hl.layer_rule({ name = "savanna-glass-blur", match = { namespace = "^savanna-glass$" }, blur = true, ignore_alpha = 0.3 })
```

The first rule stops Hyprland from fading Savanna in and out on top of its
own animations, and is worth having with any backdrop.

### Colours

By default Savanna uses your theme's colours. To change them, add a
`[savanna]` section to `~/.config/omarchy/shell.toml`. A theme can also ship
one in its own `shell.toml`. Each colour takes a hex value or a theme role
(`accent`, `foreground`, `background`, `muted`, `urgent`), and has an `-alpha`
companion (0 – 1).

```toml
[savanna]
accent = "#cba6f7"                # search field, selection, page dots
border = "#cba6f7"                # card border
glow   = "#f5c2e7"
selected-background-alpha = 0.3
```

| Key                   | Default                                 |
|-----------------------|-----------------------------------------|
| `accent`              | theme accent                            |
| `text`                | theme foreground                        |
| `tint`                | theme background, laid over the backdrop |
| `glow`                | `accent`                                |
| `selected-background` | `accent` at 0.24                        |
| `selected-border`     | `accent` at 0.75                        |
| `border`              | your Hyprland active border colour      |

## Uninstall

```sh
omarchy plugin remove x99.savanna
```

Then remove the SUPER+A binding and the Hyprland rules if you added them.

## License

[WTFPL](LICENSE).
