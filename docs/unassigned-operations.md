# Unassigned Operations

==🟣Implemented in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) but not currently bound to any key combo.== Available for binding — see the [key combo map](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/keycombo-map.md) for what's taken.

## Contents

- [Compact Mode](#compact-mode)
- [Native Fullscreen](#native-fullscreen)
- [Show Focus Highlight](#show-focus-highlight)

---

## Compact Mode

==🔵Shrink a window to a small size and dock it at the bottom of the screen==, like a per-window minimize. Windows line up left-to-right; the row wraps upward when full. Press again to restore original size and position. App-specific minimum sizes are respected (see `minShrinkSize` in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)).

==🟢Good candidate for a hyperkey binding== if you want lightweight window stashing without macOS minimize's Dock animation.

---

## Native Fullscreen

==🔵Toggle macOS native fullscreen mode== (the green-button animation). Wraps `hs.window:toggleFullScreen()`. Most users prefer the maximize toggle (fn+shift+option+up) which doesn't create a separate Space.

---

## Show Focus Highlight

==🔵Flash a colored border around the currently focused window.== Implemented in [focus.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/focus.lua) via `hs.canvas`. ==🟢Useful for locating keyboard focus== when many windows overlap on a dense multi-display setup.

==🔴Note:== The highlight timer must be stored in a module-level variable to prevent Lua GC from collecting it — see the [GC gotcha](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/dev-guide.md) in the dev guide.
