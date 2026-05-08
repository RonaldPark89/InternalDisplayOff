# InternalDisplayOff

A lightweight macOS menubar app that **disables/enables your MacBook's internal display** — giving you clamshell-mode benefits while keeping your keyboard, trackpad, and speakers fully functional.

## Why?

macOS clamshell mode requires closing the lid, which disables the keyboard and speakers. This app lets you turn off just the built-in screen so you can:

- Use only your external monitor(s)
- Keep using the MacBook keyboard and trackpad
- Keep using the MacBook speakers
- Save battery/reduce heat from the unused display

## Features

- **Menubar app** — lives in your menubar, no Dock icon
- **One-click toggle** — click the menubar icon to open the control panel
- **Global shortcut** — press `⌃⌘D` (Ctrl+Cmd+D) to toggle instantly
- **Safety first** — automatically re-enables the internal display when the app quits
- **Smart detection** — won't disable the internal display unless an external display is connected
- **Display monitoring** — detects when displays are connected/disconnected

## How It Works

Uses private CoreGraphics APIs (`CGSConfigureDisplayEnabled`) to programmatically disable/enable the built-in display at the system level. This is the same mechanism used by professional display management tools.

## Build

```bash
# Build the app
chmod +x build.sh
./build.sh

# Run it
open build/InternalDisplayOff.app

# Or install to Applications
cp -r build/InternalDisplayOff.app /Applications/
```

**Requirements:**
- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)
- An external display connected (for the toggle to work)

## Permissions

You may need to grant **Accessibility** permissions for the global keyboard shortcut to work:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Add `InternalDisplayOff` to the allowed apps

## Keyboard Shortcut

| Shortcut | Action |
|----------|--------|
| `⌃⌘D` | Toggle internal display on/off |

## Safety

- The app **will not** disable the internal display if no external display is detected
- The app **automatically re-enables** the internal display when it quits
- If something goes wrong, simply quit the app from the menubar

## Technical Notes

- Uses `CGSConfigureDisplayEnabled` (private API) — not App Store compatible, but works great for personal use
- The internal display ID is cached on launch so it can be re-enabled even after being disabled
- Uses `CGSGetOnlineDisplayList` to detect displays (includes disabled ones)
