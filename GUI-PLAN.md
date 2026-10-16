# GUI Plan — full SwiftUI window app (Option 2)

Decided 2026-10-16. **Executed 2026-10-16** — all three steps done and
regression-gated; deviations recorded at the bottom of this file.
Protocol ground truth is [SPEC.md](SPEC.md); current CLI implementation in
`ddcx.swift` / `hdr.swift` — both fully working and regression-tested.

## Scope

A native SwiftUI app ("Monitor"). Originally a settings-style window (MVP);
moved to a **MenuBarExtra accessory** on 2026-10-16 at Rich's request: no
Dock icon (LSUIElement), panel opens anchored under the menu-bar icon,
~320 pt wide, height follows content, with its own Rescan + Quit footer
(no Dock menu to quit from).

MVP surface:
- Brightness / contrast / volume sliders (VCP 0x10 / 0x12 / 0x62)
- Input picker (VCP 0x60; decode per SPEC §5 — USB-C is 0x19 on this panel)
- Mute toggle (VCP 0x8D)
- **HDR toggle with lock-aware UX** (the differentiator): when a write doesn't
  stick, run the SPEC §6.2 volume-probe heuristic; show slider as locked with
  a "Release (disable macOS HDR)" button that flips `preferHDRModes(false)`
  via MonitorPanel, then re-enables the slider
- Live value polling in the background (2–5 s cadence; each validated DDC
  read costs ~40 ms × N — never on the main thread)

Later (explicitly out of MVP): ~~KVM/PBP controls~~ (shipped 2026-10-16 —
PIP/PBP mode + sub-input pickers and a KVM next-device action, using the
delayed-verify path the layout codes require, SPEC §9.3), media-key
brightness integration, launch-at-login.

## Architecture

### Step 1 — shared-core refactor (prerequisite, pure motion)

Split `ddcx.swift` (script-style, top-level code) into:

```
Sources/DDC.swift      DDCClient: transport + rolling-stream parser (§7.2),
                       getVCP/setVCP(+verify), caps, display discovery (§8),
                       lock heuristic (§6.2)
Sources/HDR.swift      MonitorPanel read/toggle of preferHDRModes
Sources/ddcx-main.swift  thin CLI front (current verbs, exit codes 0/1/2)
MonitorApp/            Xcode project (app target) — references Sources/*.swift
```

- CLI keeps building via the Makefile: `swiftc Sources/ddcx-main.swift Sources/DDC.swift Sources/HDR.swift -o ddcx`
  (adjust for the split; `hdr` similarly).
- Regression gate after refactor: brightness 60→75 round-trip, `ddcx displays`,
  `ddcx input`, lock-heuristic test (hdr on → set fails with diagnostic → off).

### Step 2 — Xcode project via MCP

- Create `MonitorApp.xcodeproj` (SwiftUI, macOS 14+ deployment target — MenuBarExtra-class
  APIs available even though MVP is windowed).
- App target references the SAME `Sources/DDC.swift` / `Sources/HDR.swift` files
  (no code duplication between CLI and GUI).
- LSUIElement stays false for MVP (regular app); revisit menu-bar-only later.
- Build/run through the Xcode MCP tools; keep the CLI Makefile path green too.

### Step 3 — wire the UI

- DDCClient is blocking (`usleep`-paced I/O): wrap in a background actor
  (Swift concurrency) with async `getCurrent/setTarget` per display; sliders
  bind to published state, writes go through set-verify (SPEC §9.3) and
  surface ✓/✗ + lock diagnostic inline.
- Display list from `discoverDisplays()` on launch + refresh on
  `NSApplication.didChangeScreenParametersNotification`.

## Hard constraints (from SPEC)

- Never trust transport ACK as success — always write-verify.
- Never auto-switch input (0x60 write) — blanks the only display; OSD is
  unreachable. Picker must require explicit user action.
- Writes ×2 with 40 ms spacing; reads need the rolling-stream parser — do not
  "simplify" to fixed offsets (that is exactly m1ddc's bug).
- HDR lock is monitor firmware behavior: releasing it means turning macOS HDR
  off; present it as a choice, never silently.

## Environment notes

- Xcode 27.1 at /Applications/Xcode.app; `mcpbridge` is the MCP entry point.
- `xcode-select` may still point at CommandLineTools — if so, everything must
  keep using absolute paths / `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (already set in the ZCode MCP config), or the user runs
  `sudo xcode-select -s /Applications/Xcode.app`.
- Xcode MCP access must be enabled once: Xcode Settings → Intelligence →
  Model Context Protocol (or `sudo /Applications/Xcode.app/Contents/Developer/usr/bin/mcp-server enable`),
  plus `mcp-server allow-folder --path /Users/rich/Code` if headless mode asks.

## Execution notes (2026-10-16)

- Step 1 as planned, except CLI fronts live in `cli/` as `@main` structs
  built with `-parse-as-library` (keeps `Sources/` free of top-level code,
  which the app target requires). Regression gate re-run: all green.
- Step 2 deviation: the Xcode project uses a **synchronized folder**
  (`PBXFileSystemSynchronizedRootGroup`), which cannot reference files
  outside itself and ignores symlinked *directories* — but follows per-file
  symlinks. Sharing is therefore `MonitorApp/MonitorApp/{DDC,HDR}.swift →
  ../../Sources/*.swift` (one inode, zero duplication).
- Gotcha found: `cli/hdr.swift` + `Sources/HDR.swift` collide on
  case-insensitive APFS — swiftc's batch-mode objects are named after file
  basenames, so `hdr-1.o`/`HDR-1.o` overwrote each other and dropped
  `main`. Fronts renamed to `*-cli.swift`.
- Step 3 as planned (DDCGate serial queue per display, set+verify on every
  write, 3 s polling, input switch behind a confirmation dialog, HDR toggle
  + Release flow with the SPEC §6.3 2 s settle).
- Verified: build, launch, in-process discovery + live polling (thread
  sample shows `IOAVServiceReadI2C` on `ddc.gate.<uuid>`), CLI writes
  succeed concurrently with app polling. Xcode **previews** cannot reach
  IOAVService (agent sandbox) — the Live preview shows the empty state;
  run the app instead.
