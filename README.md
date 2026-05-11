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

## Changelog

### v1.00.01
- **Robust Auto-Recovery:** The internal display now automatically and reliably turns back on when all external monitors are disconnected, bypassing macOS WindowServer sleep states and correctly filtering out virtual "ghost" displays.
- **HUD Toast Notifications:** Added sleek, unobtrusive floating toast messages to notify you when the internal display state changes (can be toggled in settings).
- **Reactive UI:** The menu bar icon now instantly and accurately reflects the display state using Combine, fixing occasional desync issues.
- **Hot-plug Stability:** Fixed a bug where rapidly plugging and unplugging external monitors caused duplicate ghost monitors to be counted.
- **Enhanced Backup System:** The internal display ID is now persistently backed up to both UserDefaults and a local hidden file (`~/.internal_display_backup_id`), ensuring recovery is always possible even across reboots or app crashes.

## How It Works

Uses private CoreGraphics APIs (`CGSConfigureDisplayEnabled`) to programmatically disable/enable the built-in display at the system level. This is the same mechanism used by professional display management tools.
![image](https://private-user-images.githubusercontent.com/2907720/589612799-aa7e0871-cc38-428e-96d1-2deb142de301.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NzgyNTEyMzYsIm5iZiI6MTc3ODI1MDkzNiwicGF0aCI6Ii8yOTA3NzIwLzU4OTYxMjc5OS1hYTdlMDg3MS1jYzM4LTQyOGUtOTZkMS0yZGViMTQyZGUzMDEucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI2MDUwOCUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNjA1MDhUMTQzNTM2WiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9YWM4OTM2ZDM1OThjODUxYzZkZGVjYjlkZWZkODY1MmNhMDgxYTgzZjE4MTliMTdkN2MwNWVmMDgyOTY5YjIyNSZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QmcmVzcG9uc2UtY29udGVudC10eXBlPWltYWdlJTJGcG5nIn0.XZFE1_O8W9QuSuLiZn5TbjQIKV7KsduZQ0iiCjtxYPw)

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
