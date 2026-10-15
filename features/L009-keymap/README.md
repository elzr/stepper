# L009-keymap

> ==🔴Superseded on 2026-10-09 by [F002](https://fleet.internal/features/F002-harmonious-keybindings/)'s [keymap](https://fleet.internal/features/F002-harmonious-keybindings/subfeatures/keymap/keymap.html)==, which grew out of this one: every ◆ hyperkey and rcmd right-⌥ key as an A–Z list that turns into a keyboard, with the live slots, the Bear note bindings, and the clashes [F002](https://fleet.internal/features/F002-harmonious-keybindings/)'s census finds across every app.

==🔵Hidden from featurebase's search since 2026-10-15==, kept for history. Its [Modifiers](#modifiers) tables, written that morning, became the [Modifiers card of F002/keymap](https://fleet.internal/features/F002-harmonious-keybindings/subfeatures/keymap/README.md#modifiers) the same day, which stays current by itself; the tables below are that morning's snapshot.

## Contents

- [Modifiers](#modifiers)
  - [Double mods and modifier chords](#double-mods-and-modifier-chords)
  - [Mod-spacing](#mod-spacing)
  - [Mod-tabbing](#mod-tabbing)
  - [Traps](#traps)
- [What it was](#what-it-was)
- [Where each piece went](#where-each-piece-went)
- [Why it moved](#why-it-moved)

## Modifiers

Starts from the Bear notes [_keys Mod-spacing](bear://x-callback-url/open-note?id=7B8F4599-D155-4AD7-985C-06376DF3930E) and [_keys Mod-tabbing](bear://x-callback-url/open-note?id=35C6BFFC-4A20-445D-91E5-E1C1366B69A8), ==🔵checked against each app's own config on 2026-10-15==: BetterTouchTool's `bttcli get_triggers`, Raycast's hotkey log, AltTab's, superwhisper's and Monologue's preferences, ChatGPT's `~/.codex` state and [F002](https://fleet.internal/features/F002-harmonious-keybindings/)'s [census](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/subfeatures/census/keybindings-census.json). The **vs. notes** column says what changed since the notes were written. ◆ is Caps Lock through Hyperkey (⌃⌥⇧⌘).

### Double mods and modifier chords

==🟢One finger, either hand, and a toggle rather than a search== (the note's why). They live in BetterTouchTool because it tells left from right modifiers.

| Keys | Does | Set in | vs. notes |
|---|---|---|---|
| ⌘ ⌘ (either side) | Raycast root search (sends ⌘Space) | BTT | ✓ |
| ⌥ ⌥ (either side) | Bear Notes search in a new window, via Raycast deeplink `raycast://extensions/hmarr/bear/index` | BTT | changed: sent ⌥Space until 2026-10-08, when ChatGPT's pet grabbed ⌥Space |
| left ⌃ ⌃ | menu search: focus the menu bar (sends ⌃F2) | BTT | ✓ left only |
| r⌘ ; | same menu search (⌃F2) | BTT | ✓ |
| r⌥ ; | menu bar as a context menu at the cursor (alias of ⇧⌥`) | BTT | ✓ |
| `\` `\` | Quick Soulver (sends ⌥⌘Space) | BTT | ✓ |
| left⇧ ; ; (typing `::`) | Raycast emoji (sends ⌃⌥Space) | BTT | ✓ |
| `'` `'` | Calculate & Append with Soulver (sends ⌃⇧← to preselect the line first) | BTT, ==🔵Bear only== | ✓, scoped to Bear |
| ==🟢L⌘ + R⌘ together== | Raycast › System › Sleep Displays | Raycast | ==🟢new 2026-10-15==, for walking away from the agents at the club |
| ~~r⇧ r⇧~~ | ~~Raycast window selection~~ | — | ==🔴gone==: no BTT trigger on right ⇧; ⌥⇥ does it |
| ~~⌘ + ⌘ (ChatGPT)~~ | ~~ChatGPT Appshot~~ | — | ==🔴switched off 2026-10-15==: `"appshotHotkey": null` in `~/.codex/.codex-global-state.json`; its log says `Appshot hotkey inactive`. Re-enable in ChatGPT › Settings, which offers ⌘+⌘, ⌥+⌥ or ⇧+⇧ (⌥+⌥ would sit on BTT's ⌥ ⌥) |

### Mod-spacing

Great for searches, per the note.

| Keys | Does | Set in | vs. notes |
|---|---|---|---|
| ⌘Space | Raycast root search | Raycast | ✓ |
| ⇧⌘Space | Paste (clipboard) | Paste | ✓ |
| ⌥Space | Bear Notes search | Raycast | ✓; ChatGPT's pet default is nulled in `~/.codex/keybindings.json` |
| ⌥. | Raycast file search | Raycast | ✓ |
| ⌥⇧, | Raycast folder search | Raycast | new since the notes (their ⌘. folder search is deprecated) |
| ⌥⌘Space | Quick Soulver | Soulver Mini | ✓ |
| ⌃⌥Space | Raycast emoji | Raycast | ✓ (was Spotlight; macOS's Spotlight keys are off) |
| ⌃⌘Space | macOS Emoji & Symbols (good for dashes) | macOS Edit menu | ✓ |
| ⌃⇧Space | superwhisper hands-free toggle | superwhisper | ==🔴dormant==: still set, but superwhisper isn't running. Monologue (⌃M, record a note) is the voice app that runs |
| ~~⇧⌥Space~~ | ~~superwhisper push-to-talk~~ | — | ==🔴gone==: superwhisper keeps no push-to-talk key now. ⇧⌥Space is free |
| ⌃Space | nothing (it got hit by accident) | — | ✓ unowned; BTT's F15 sends it |
| ⌃⌥⌘Space, ◆Space | free | — | ✓ both free |

### Mod-tabbing

Great for switching between and searching what's open, per the note.

| Keys | Does | Set in | vs. notes |
|---|---|---|---|
| ⌘⇥ | app/window switcher | ==🔵AltTab== (hold ⌘, next ⇥) | changed: AltTab's trial replaced macOS's switcher ([fleet F040/AltTab](https://fleet.internal/features/F040-tiptop-software-infrastructure/), with the dead-⌘⇥ watcher in [cmdtabwatch.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/cmdtabwatch.lua)) |
| ⌥⇥ | Raycast Switch Windows | Raycast | ✓ |
| ⌥1 | activate previous window (a toggle) | BTT | ✓ |
| ⌘` | activate previous window, skipping minimized | BTT | changed: was the deprecated stage cycling |
| ⇧⌥` | menu bar as a context menu at the cursor | BTT | ✓ |
| ⇧⌘/ (⌘?) | search the menus (Help) | macOS | ✓ |
| ~~⌥`~~ | ~~stages as a context menu~~ | — | ==🔴gone== with Stage Manager: no trigger on ⌥` |
| ~~fn L~~ | ~~Chrome tab search, Alfred Browser Tabs workflow~~ | — | ==🔴dead==: Alfred 4 is installed but doesn't run |

### Traps

- ==🔴Never bind ◆⎋==. Tapping Caps alone makes Hyperkey send Escape *with the four modifiers held*, so ◆⎋ fires on every Caps tap. On 2026-10-14 Raycast's hotkey recorder took the Esc meant to dismiss it as the hotkey, and Sleep Displays fired on each Caps tap until 2026-10-15. It looked like the four externals blinking off and on.
- ==🔵Modifier-only hotkeys don't reach the census==: Raycast logs L⌘+R⌘ as `⌘⏴⏵`, and the [census](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/subfeatures/census/keybinding-census.py)'s Raycast reader only parses `mods #keycode`, so it drops them. ChatGPT's bare-modifier monitor is seen only while ChatGPT runs. This table is the record for both until the census reads them.

## What it was

A Hammerspoon module ([stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) loaded it from 2026-04-19) that read rcmd's plist, stepper's hotkey data and a hand-written `notes.jsonc`, and wrote `keymap.html`: a MacBook Pro keyboard with colored underlines per layer, a bindings table, and drift warnings when a note no longer matched rcmd. Pathwatchers regenerated it on every change.

## Where each piece went

| Was here | Now |
|---|---|
| `keymap.html` (keyboard + table) | [F002/keymap.html](https://fleet.internal/features/F002-harmonious-keybindings/subfeatures/keymap/keymap.html), drawn in the browser from the census |
| `keymap.lua` reading rcmd and stepper's data | [F002/keybinding-census.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/subfeatures/census/keybinding-census.py), which reads every other app too |
| its pathwatchers | [lua/keymapwatch.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/keymapwatch.lua), which reruns the census |
| `notes.jsonc` (mnemonics, Bear notes, drift checks) | [F002/keymap-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/subfeatures/keymap/keymap-notes.jsonc), reseeded from the Bear note [_app rcmd](bear://x-callback-url/open-note?id=DC12D4B5-3818-437A-9143-D5B6A783A89B) |

The code is in git history: `git log --all -- features/L009-keymap/keymap.lua`.

## Why it moved

==🔵A keymap is half of keeping shortcuts harmonious==: it shows who owns each key, and the [F002](https://fleet.internal/features/F002-harmonious-keybindings/) census shows which owners collide. Kept apart, they read the same sources twice and still missed the apps neither one read, such as Paste holding ◆C. Together, one census feeds both.
