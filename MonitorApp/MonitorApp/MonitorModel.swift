//
// MonitorModel — app-side model wrapping the shared DDC/HDR core.
//
// DDCClient I/O is blocking and usleep-paced (SPEC §2.3), so every bus
// operation is funneled through DDCGate: one serial utility queue per
// display (half-duplex, one exchange in flight), bridged to async with
// continuations. The model itself is @MainActor/@Observable for the UI.
//
// Write policy (SPEC §9.3): every set goes through setAndVerify — transport
// ACK is never trusted. The §6.2 lock discrimination surfaces as a per-
// control "locked" state with a "Release (disable macOS HDR)" action.
//

import SwiftUI
import AppKit
import IOKit

// MARK: - Serial I/O gate per display

actor DDCGate {
    @ObservationIgnored private let client: DDCClient
    @ObservationIgnored private let queue: DispatchQueue

    init(client: DDCClient) {
        self.client = client
        self.queue = DispatchQueue(label: "ddc.gate.\(client.uuid)", qos: .utility)
    }

    func get(_ vcp: UInt8) async -> VCPReply? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.client.getVCP(vcp)) }
        }
    }

    func set(_ vcp: UInt8, _ value: UInt16) async -> SetResult {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.client.setAndVerify(vcp, value)) }
        }
    }

    /// Unverified write for layout/USB codes (0xE7–0xE9): the write lands,
    /// but the panel stonewalls same-code reads for ~2–4 s afterwards, so
    /// verification is a delayed re-read by the caller.
    func setUnverified(_ vcp: UInt8, _ value: UInt16) async -> Bool {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.client.setVCP(vcp, value: value)) }
        }
    }

    func errorText() -> String {
        queue.sync { client.lastError ?? "" }
    }
}

// MARK: - Per-control UI state

struct ControlState {
    var current: Int = 0
    var max: Int = 100
    var status: String = ""     // transient ✓ / ✗ / diagnostic, cleared after a moment
    var locked = false          // §6.2: HDR signal lock confirmed for this VCP
    var editing = false         // slider drag in progress (poll must not fight it)
    var writing = false
}

// MARK: - Display model

@MainActor @Observable
final class DisplayModel: Identifiable {
    let id: UUID
    let uuid: String
    let name: String
    let chip: UInt32

    @ObservationIgnored private let gate: DDCGate
    @ObservationIgnored private var hdrDisplay: HDRControl.Display?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var statusClearTask: Task<Void, Never>?
    @ObservationIgnored private var energyWatchTask: Task<Void, Never>?

    var controls: [UInt8: ControlState] = [
        0x10: ControlState(),   // brightness
        0x12: ControlState(),   // contrast
        0x62: ControlState(),   // volume
    ]
    var inputCode: Int?                     // low byte of VCP 0x60
    var muteOn: Bool?                       // VCP 0x8D: 1 = muted, 2 = unmuted, nil unknown
    var kvmValue: Int?                      // VCP 0xE7 raw; encoding undocumented (0xBC00 base observed)
    var pbpMode: Int?                       // VCP 0xE9: 0 off · 33/34 PIP · 36/43/44/65 PBP
    var pbpInput: Int?                      // VCP 0xE8 sub-window input (meaningful only with a mode active)

    /// Codes proven live on this display (SPEC §5.4 probed-reality method):
    /// a control is only shown when its VCP answered with a real frame.
    /// This panel's firmware replies to unsupported codes with a degenerate
    /// frame (current 0 · max 65535 · type 0); other panels usually just
    /// stay silent — both count as absent.
    var supported: Set<UInt8> = []
    var hdrCapable = false
    var hdrOn = false
    var hdrBusy = false
    var lastError: String?
    private(set) var ioBusy = false         // a write/verify cycle is in flight

    init(client: DDCClient) {
        self.id = UUID()
        self.uuid = client.uuid
        self.name = client.name
        self.chip = client.chip
        self.gate = DDCGate(client: client)
    }

    var anyLocked: Bool { controls.values.contains { $0.locked } }

    // MARK: Refresh (initial + on screen-layout changes)

    func start() {
        Task { await refreshAll() }
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshAll() async {
        refreshHDRState()
        for vcp in [UInt8(0x10), 0x12, 0x62, 0x60, 0x8D, 0xE7, 0xE8, 0xE9] {
            if ioBusy { return }
            await readControl(vcp)
        }
    }

    private func readControl(_ vcp: UInt8) async {
        guard let r = await gate.get(vcp) else { return }   // silent ≠ unsupported (write quiet periods)
        if r.current == 0, r.max == 0xFFFF, r.type == 0 {
            supported.remove(vcp)   // degenerate reply — code absent on this panel
            return
        }
        supported.insert(vcp)
        switch vcp {
        case 0x60:
            inputCode = r.current & 0xFF
        case 0x8D:
            muteOn = r.current == 1 ? true : r.current == 2 ? false : nil
        case 0xE7:
            kvmValue = r.current
        case 0xE8:
            pbpInput = r.current
        case 0xE9:
            pbpMode = r.current
        default:
            controls[vcp, default: ControlState()].current = r.current
            controls[vcp, default: ControlState()].max = max(r.max, 1)
        }
    }

    // MARK: HDR state (MonitorPanel, same mechanism System Settings uses)

    func refreshHDRState() {
        guard let displays = HDRControl.displays() else { return }
        // Correlate by display name — registry ProductName and MonitorPanel
        // displayName both read "DELL U4025QW" on this system.
        let candidates = displays.filter { !$0.isBuiltIn }
        hdrDisplay = candidates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? candidates.first
        if let d = hdrDisplay {
            hdrCapable = d.isHDRCapable
            hdrOn = d.prefersHDR
        }
    }

    func setHDR(_ on: Bool) {
        guard let d = hdrDisplay, hdrCapable, !hdrBusy else { return }
        hdrBusy = true
        // Keep MonitorPanel traffic on the main thread — the known-good path
        // (System Settings / the hdr CLI). One 400 ms settle inside.
        Task { @MainActor in
            defer { hdrBusy = false }
            if HDRControl.setPrefersHDR(on, for: d) == nil {
                lastError = "macOS HDR toggle did not take"
            }
            refreshHDRState()
        }
    }

    /// §6.3 release: turn macOS HDR off, wait out the ~2 s settle, then
    /// clear lock state and re-read every control. Explicit user action only.
    func releaseLock() {
        guard let d = hdrDisplay, !hdrBusy else { return }
        hdrBusy = true
        Task { @MainActor in
            defer { hdrBusy = false }
            if HDRControl.setPrefersHDR(false, for: d) != nil {
                hdrOn = false
            }
            try? await Task.sleep(for: .seconds(2))
            for k in controls.keys { controls[k]?.locked = false }
            await refreshAll()
        }
    }

    // MARK: Writes (set + verify, SPEC §9.3)

    func commit(_ vcp: UInt8, _ value: Int) {
        ioBusy = true
        controls[vcp]?.writing = true
        // Brightness energy gate: the firmware pops an on-monitor confirmation
        // when brightness goes above 75 (ENERGY STAR default). The DDC write
        // itself verifies ✓, but the value reverts to 75 after ~15 s unless a
        // physical button is pressed. Warn on the upward crossing and verify
        // the outcome afterwards.
        let crossedEnergyGate = vcp == 0x10
            && value > Self.energyConfirmThreshold
            && (controls[vcp]?.current ?? 0) <= Self.energyConfirmThreshold
        Task {
            defer {
                ioBusy = false
                controls[vcp]?.writing = false
            }
            let result = await gate.set(vcp, UInt16(clamping: value))
            await apply(result, to: vcp, attempted: value)
            if case .ok = result, vcp == 0x10, value > Self.energyConfirmThreshold {
                if crossedEnergyGate {
                    controls[vcp]?.status = "press any monitor button to confirm"
                }
                watchEnergyConfirm(attempted: value)
            }
        }
    }

    /// Brightness above the energy threshold only sticks if confirmed with a
    /// physical monitor button within ~15 s; otherwise the firmware reverts
    /// to 75. Re-read after the window closes and report which happened.
    private func watchEnergyConfirm(attempted: Int) {
        energyWatchTask?.cancel()
        energyWatchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(18))
            guard let self, !Task.isCancelled else { return }
            guard let r = await self.gate.get(0x10) else { return }
            self.controls[0x10]?.current = r.current
            if r.current >= attempted {
                self.controls[0x10]?.status = "✓ confirmed"
            } else {
                self.controls[0x10]?.status = "reverted to \(r.current) — needs one physical button press"
            }
            try? await Task.sleep(for: .seconds(4))
            self.controls[0x10]?.status = ""
        }
    }

    /// VCP 0x10 value above which the monitor demands a physical energy
    /// confirmation (Dell ENERGY STAR nag; reverts to this value on timeout).
    static let energyConfirmThreshold = 75

    func commitInput(_ code: Int) {
        ioBusy = true
        Task {
            defer { ioBusy = false }
            let result = await gate.set(0x60, UInt16(code))
            switch result {
            case .ok:
                inputCode = code & 0xFF
                setStatus(0x60, "✓ switched to \(inputCodeName(code))")
            default:
                await apply(result, to: 0x60, attempted: code)
            }
        }
    }

    func commitMute(_ on: Bool) {
        ioBusy = true
        Task {
            defer { ioBusy = false }
            let result = await gate.set(0x8D, on ? 1 : 2)
            switch result {
            case .ok:
                muteOn = on
                setStatus(0x8D, "✓")
            default:
                muteOn = nil
                await apply(result, to: 0x8D, attempted: on ? 1 : 2)
            }
        }
    }

    // MARK: Layout & KVM writes (delayed verify, SPEC §9.3 note)

    /// Write a layout/USB code (0xE7–0xE9), wait out the panel's ~2–4 s
    /// same-code read quiet period, then re-read and report the outcome.
    /// `command` semantics (KVM next) treat any read-back as informational.
    private func commitLayout(_ vcp: UInt8, _ value: Int, command: Bool = false,
                              onRead: @escaping @MainActor (Int) -> Void) {
        ioBusy = true
        Task {
            defer { ioBusy = false }
            guard await gate.setUnverified(vcp, UInt16(clamping: value)) else {
                lastError = await gate.errorText()
                setStatus(vcp, "✗ write failed")
                return
            }
            setStatus(vcp, "sent — checking…")
            for delay in [UInt64(3), 3] {
                try? await Task.sleep(for: .seconds(delay))
                if let r = await gate.get(vcp) {
                    onRead(r.current)
                    if command {
                        setStatus(vcp, "→ 0x\(String(r.current, radix: 16))")
                    } else {
                        setStatus(vcp, r.current == value ? "✓ \(r.current)" : "now \(r.current)")
                    }
                    return
                }
            }
            setStatus(vcp, "sent (no read-back yet — re-checking later)")
        }
    }

    func commitPBPMode(_ mode: Int) {
        commitLayout(0xE9, mode) { self.pbpMode = $0 }
        // Layout changes re-arrange the desktop and can shove this window
        // off the visible area — re-assert visibility once the monitor has
        // settled (mode switch + any display renegotiation).
        Task {
            try? await Task.sleep(for: .seconds(4))
            Self.reassertWindowVisibility()
        }
    }

    /// Center the main app window on the main screen and bring it to
    /// front. Used after PIP/PBP writes — the recovery path when a layout
    /// change strands the control surface (observed 2026-10-16).
    static func reassertWindowVisibility() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        for window in NSApp.windows where window.canBecomeMain && window.isVisible {
            var frame = window.frame
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
            window.setFrameOrigin(frame.origin)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            break
        }
    }

    func commitPBPInput(_ code: Int) {
        commitLayout(0xE8, code) { self.pbpInput = $0 }
    }

    func commitKVMNext() {
        commitLayout(0xE7, 0xFF00, command: true) { self.kvmValue = $0 }
    }

    private func apply(_ result: SetResult, to vcp: UInt8, attempted: Int) async {
        switch result {
        case .ok(let readBack):
            if vcp != 0x60, vcp != 0x8D {
                controls[vcp]?.current = readBack
            }
            setStatus(vcp, "✓ \(readBack)")
        case .writeFailed:
            lastError = await gate.errorText()
            setStatus(vcp, "✗ write failed")
        case .noReply:
            setStatus(vcp, "✗ no reply")
        case .mismatch(let readBack):
            if vcp != 0x60, vcp != 0x8D {
                controls[vcp]?.current = readBack   // snap back to monitor truth
            }
            setStatus(vcp, "✗ value did not stick (\(readBack))")
        case .locked:
            controls[vcp]?.locked = true
            refreshHDRState()
            setStatus(vcp, "locked by macOS HDR")
        }
    }

    private func setStatus(_ vcp: UInt8, _ text: String) {
        if controls[vcp] == nil {
            // codes without a persistent slider state (input, mute, KVM,
            // PBP) flash their outcome via the transient status map
            transientStatus[vcp] = text
        } else {
            controls[vcp]?.status = text
        }
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.controls[vcp]?.status = ""
            self?.transientStatus[vcp] = nil
        }
    }

    var transientStatus: [UInt8: String] = [:]

    // MARK: Background polling (GUI-PLAN: 2–5 s cadence, off the main thread)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !self.ioBusy else { continue }
                for vcp in [UInt8(0x10), 0x12, 0x62] {
                    if self.ioBusy { break }
                    // never fight an in-progress drag: the commit will land
                    guard self.controls[vcp]?.editing != true else { continue }
                    if let r = await self.gate.get(vcp) {
                        self.controls[vcp]?.current = r.current
                        self.controls[vcp]?.max = max(r.max, 1)
                    }
                }
                if !self.ioBusy, let r = await self.gate.get(0xE9) {
                    self.pbpMode = r.current   // catch OSD/stranded changes too
                }
                self.refreshHDRState()
            }
        }
    }
}

// MARK: - App model

@MainActor @Observable
final class AppModel {
    var displays: [DisplayModel] = []
    var scanning = false
    @ObservationIgnored private var refreshDebounce: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        scheduleRefresh()
    }

    func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task {
            try? await Task.sleep(for: .seconds(1))   // let AV services settle
            guard !Task.isCancelled else { return }
            await refreshDisplays()
        }
    }

    func refreshDisplays() async {
        scanning = true
        defer { scanning = false }
        // Registry walk + AV service creation — off the main actor.
        let clients = await Task.detached(priority: .utility) {
            DDCClient.discover()
        }.value

        let old = displays
        var models: [DisplayModel] = []
        for client in clients {
            if let existing = old.first(where: { $0.uuid == client.uuid && !client.uuid.isEmpty }) {
                models.append(existing)
            } else {
                let m = DisplayModel(client: client)
                models.append(m)
                m.start()
            }
        }
        for removed in old where !models.contains(where: { $0.id == removed.id }) {
            removed.stop()
        }
        displays = models
    }
}
