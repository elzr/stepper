# Key Combo Map

Modifier symbols: ⌃ Control · ⌥ Option · ⇧ Shift · ⌘ Command · ◆ Hyperkey (⌃⌥⇧⌘)

All fn combos use fn+arrow which Hammerspoon sees as Home/End/PageUp/PageDown.

## Window Operations (fn + modifier + ↔↕)

```
           ↕                ↕                ↕                  ↕
           │                │                │                  │
       ← ──┼── →        ← ──┼── →        ← ──┼── →         ← ──┼── →
           │                │                │                  │
           ↕                ↕                ↕                  ↕

       (none)              ⇧               ⌃                 ⌃⇧
        Move             Resize         Snap to edge     Resize to edge
```

| Modifier | ↔↕ | Action |
|----------|-----|--------|
| *(none)* | ↔↕ | Step move |
| ⇧ | ↔↕ | Step resize (bottom-right corner) |
| ⌃ | ↔↕ | Snap to screen edge (repeat undoes) |
| ⌃⇧ | ↔↕ | Resize to screen edge (repeat undoes) |
| ⌥ | ↔↕ | Shrink/grow toggle |
| ⇧⌥ | ↔ | Half → third → mid third → two-thirds → restore cycle |
| ⇧⌥ | ↑ | Maximize cycle (height → full → restore) |
| ⇧⌥ | ↓ | Center toggle (V → H → restore) |

## Focus (⌘/⌥⌘ + ↔↕)

| Modifier | ↔↕ | Action |
|----------|-----|--------|
| ⌘ | ↔↕ | Focus nearest window on same screen |
| ⌥⌘ | ↔↕ | Focus nearest window on adjacent screen |
| ⌘ | Delete | Flash highlight on focused window |

## Move to Display (⌃⌥ + ↔↕/Enter)

No fn — direct arrow keys. Repeat same combo within 1 hour to undo.

```
                 ┌─────────────┐
                 │  ⌃⌥ ↑ Top   │
                 └─────────────┘

  ┌──────────┐   ┌─────────────┐   ┌───────────┐
  │ ⌃⌥ ←     │   │ ⌃⌥ Enter    │   │   ⌃⌥ →    │
  │ Left     │   │ Center      │   │   Right   │
  └──────────┘   └─────────────┘   └───────────┘

                 ┌─────────────┐
                 │  ⌃⌥ ↓       │
                 │  Built-in   │
                 └─────────────┘
```

Position preserved. Oversized windows shrink to fit (restored when moved back).

| ⌃⌥ | Delete | Restore saved window layout |

## Shrink/Grow Detail (⌥ + ↔↕)

| Modifier | ↔↕ | Action |
|----------|-----|--------|
| ⌥ | ← | Toggle shrink width to minimum |
| ⌥ | ↑ | Toggle shrink height to minimum |
| ⌥ | → | Restore width, or grow to right edge |
| ⌥ | ↓ | Restore height, or grow to bottom edge |

## Mouse Move

| Trigger | Action |
|---------|--------|
| fn + move | Move window under cursor |
| fn ⇧ + move | Resize (grab position determines behavior) |

```
  ┌────┬────┬────┐
  │ ↖  │ ↑  │ ↗  │   Corner → resize from that corner
  ├────┼────┼────┤   Edge   → resize that edge
  │ ←  │ ✥  │ →  │   Center → move window
  ├────┼────┼────┤
  │ ↙  │ ↓  │ ↘  │
  └────┴────┴────┘
```

## Bear Note HUD (◆ + letter)

| Key | Note |
|-----|------|
| N | _mem NOW |
| R | _app rcmd |
| D | Weekly days |
| W | Weekly work |
| T | Weekly thoughts |
| S | _topsight 2026 |
| I | _index 2026 |
| X | live window (set with R⌥) |
| Q | live window (set with R⌥) |
| A | live window (set with R⌥) |
| Z | live window (set with R⌥) |

Toggle: open → raise → minimize (macOS auto-focuses previous window).
Summon (R⇧ + ◆ letter): summon to cursor → return + minimize.
Past week (R⌘ + ◆ D/W/T): open previous week's note.
Next week (R⌥ + ◆ D/W/T): open next week's note.
