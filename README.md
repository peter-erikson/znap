<p align="center">
  <img src="assets/znap_icon_readme.png" alt="Znap icon" width="360">
</p>

# Znap

A dependency-free hotkey oriented window manager for Windows 10 & 11 inspired by Rectangle for MacOS, with additional window layout snapshot store/recall functionality. 

## Default Hotkeys

| Action | Shortcut |
| --- | --- |
| Cycle the left edge through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `Left` |
| Cycle the right edge through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `Right` |
| Cycle the top edge through 1/2, 2/3, and 1/3 height | `Win` + `Ctrl` + `Alt` + `Up` |
| Cycle the bottom edge through 1/2, 2/3, and 1/3 height | `Win` + `Ctrl` + `Alt` + `Down` |
| Cycle the top-left corner through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `Insert` |
| Cycle the top-right corner through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `Page Up` |
| Cycle the bottom-left corner through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `Delete` |
| Cycle the bottom-right corner through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `Page Down` |
| Cycle a centered, full-height window through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `\` |
| Toggle maximize, restoring the previous state or a centered state if unknown | `Win` + `Ctrl` + `Alt` + `Enter` |
| Toggle always-on-top | `Win` + `Ctrl` + `Alt` + `A` |
| Store the currently fully visible windows and window focus in snapshot 1–9 or 0 (ignoring always-on-top overlays) | `Win` + `Shift` + `Alt` + `1`–`9` or `0` |
| Recall snapshot 1–9 or 0, raise its windows, promote them in Alt+Tab, and restore focus | `Win` + `Ctrl` + `Alt` + `1`–`9` or `0` |

The notification-area menu links to the original documentation, toggles launch at sign-in, and exits the application.
Successfully stored windows briefly wiggle down and back up as confirmation.

## Build

Install Zig 0.16.0, then run:

```powershell
zig build -Doptimize=ReleaseSafe
```

The executable is written to `zig-out/bin/Znap.exe`. No Go runtime or third-party Zig package is required.

Run the unit tests with:

```powershell
zig build test
```

## Implementation

The application calls Win32 directly. Its C declarations are generated at build time with Zig's `addTranslateC`; window geometry and saved maximize states are kept in platform-independent modules with unit tests. It uses per-monitor-v2 DPI awareness, DWM extended frame bounds, monitor work areas, global hotkeys, a native notification-area icon, and the current-user `Run` registry key.

## License and attribution

The window snapping functionality is a Zig-language port of RectangleWin by Ahmet Alp Balkan. It preserves the upstream behavior and is distributed under the Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

