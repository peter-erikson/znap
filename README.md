# RectangleWin (Zig port)

A dependency-free Zig 0.16 port of [ahmetb/RectangleWin](https://github.com/ahmetb/RectangleWin), a hotkey-oriented window snapping utility for Windows 10 and 11.

## Hotkeys

| Action | Shortcut |
| --- | --- |
| Cycle the left edge through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `Left` |
| Cycle the right edge through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `Right` |
| Cycle the top edge through 1/2, 2/3, and 1/3 height | `Win` + `Ctrl` + `Alt` + `Up` |
| Cycle the bottom edge through 1/2, 2/3, and 1/3 height | `Win` + `Ctrl` + `Alt` + `Down` |
| Cycle the top-left corner through 1/2, 2/3, and 1/3 width | `Win` + `Shift` + `Alt` + `Left` |
| Cycle the top-right corner through 1/2, 2/3, and 1/3 width | `Win` + `Shift` + `Alt` + `Up` |
| Cycle the bottom-left corner through 1/2, 2/3, and 1/3 width | `Win` + `Shift` + `Alt` + `Down` |
| Cycle the bottom-right corner through 1/2, 2/3, and 1/3 width | `Win` + `Shift` + `Alt` + `Right` |
| Cycle a centered, full-height window through 1/2, 2/3, and 1/3 width | `Win` + `Ctrl` + `Alt` + `C` or `Win` + `Ctrl` + `Alt` + `\` |
| Maximize the current window | `Win` + `Ctrl` + `Alt` + `F` |
| Toggle always-on-top | `Win` + `Ctrl` + `Alt` + `A` |

The notification-area menu links to the original documentation, toggles launch at sign-in, and exits the application.

## Build

Install Zig 0.16.0, then run:

```powershell
zig build -Doptimize=ReleaseSafe
```

The executable is written to `zig-out/bin/RectangleWin.exe`. No Go runtime or third-party Zig package is required.

Run the unit tests with:

```powershell
zig build test
```

## Implementation

The application calls Win32 directly. Its C declarations are generated at build time with Zig's `addTranslateC`; window geometry is kept in a platform-independent module with unit tests. It uses per-monitor-v2 DPI awareness, DWM extended frame bounds, monitor work areas, global hotkeys, a native notification-area icon, and the current-user `Run` registry key.

## License and attribution

This is a clean Zig-language port of RectangleWin by Ahmet Alp Balkan. It preserves the upstream icon assets and behavior and is distributed under the Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
