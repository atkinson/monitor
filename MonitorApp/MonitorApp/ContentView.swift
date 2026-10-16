//
// ContentView — compact menu-bar panel, one section per discovered display.
// Sized for MenuBarExtra(.window): ~320 pt wide, height follows content,
// transient (closes on click-away), with a Quit control since an accessory
// app has no Dock menu (macOS HIG — menu bar extras).
//

import SwiftUI
import AppKit

struct ContentView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.displays.isEmpty {
                emptyState
            } else {
                ForEach(model.displays) { display in
                    DisplaySection(model: display)
                    if display.id != model.displays.last?.id {
                        Divider()
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .overlay {
            if model.scanning && model.displays.isEmpty {
                scanningOverlay
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "display")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No DDC displays")
                .font(.headline)
            Text("Connect a display over USB-C or DisplayPort and it appears here automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var scanningOverlay: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scanning displays…").foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button {
                model.scheduleRefresh()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Re-discover displays")
            Spacer()
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Monitor", systemImage: "power")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - One display

struct DisplaySection: View {
    let model: DisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if model.supported.contains(0x10) {
                VCPSliderRow(model: model, vcp: 0x10, label: "Brightness", icon: "sun.max")
                if (model.controls[0x10]?.current ?? 0) > DisplayModel.energyConfirmThreshold {
                    Text("above \(DisplayModel.energyConfirmThreshold) sticks only after one press of any monitor button (~15 s)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 26)
                }
            }
            if model.supported.contains(0x12) {
                VCPSliderRow(model: model, vcp: 0x12, label: "Contrast", icon: "circle.lefthalf.filled")
            }
            if model.supported.contains(0x62) {
                VCPSliderRow(model: model, vcp: 0x62, label: "Volume", icon: "speaker.wave.2")
            }

            if model.supported.contains(0x8D) || model.supported.contains(0x60)
                || model.supported.contains(0xE9) || model.supported.contains(0xE7) {
                Divider()
            }

            if model.supported.contains(0x8D) { muteRow }
            if model.supported.contains(0x60) { inputRow }
            if model.supported.contains(0xE9) { pbpRow }
            if model.supported.contains(0xE8), (model.pbpMode ?? 0) != 0 {
                pbpInputRow
            }
            if model.supported.contains(0xE7) { kvmRow }
            hdrRow

            if model.anyLocked {
                lockBanner
            }
            if let err = model.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.name)
                .font(.headline)
            Spacer()
            Text("chip 0x\(String(model.chip, radix: 16))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var muteRow: some View {
        Toggle(isOn: Binding(
            get: { model.muteOn ?? false },
            set: { model.commitMute($0) }
        )) {
            Label(
                model.muteOn == nil ? "Mute (unknown)" : "Mute",
                systemImage: "speaker.slash"
            )
            .font(.callout)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.ioBusy)
        .overlay(alignment: .trailing, content: {
            if let s = model.transientStatus[0x8D] { statusText(s) }
        })
    }

    private var inputRow: some View {
        Picker(selection: Binding(
            get: { model.inputCode ?? -1 },
            set: { pendingInput = $0 }
        )) {
            Text("Input").tag(-1)
            ForEach(pickerInputs, id: \.code) { entry in
                Text(entry.label).tag(Int(entry.code))
            }
            if let cur = model.inputCode, !pickerInputs.contains(where: { Int($0.code) == cur }) {
                Text(inputCodeName(cur)).tag(cur)
            }
        } label: {
            Label("Input", systemImage: "rectangle.on.rectangle")
                .font(.callout)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(model.ioBusy)
        .overlay(alignment: .trailing, content: {
            if let s = model.transientStatus[0x60] { statusText(s) }
        })
        .confirmationDialog(
            "Switch input to \(pendingInput.map(inputCodeName) ?? "")?",
            isPresented: Binding(get: { pendingInput != nil && pendingInput != model.inputCode },
                                 set: { if !$0 { pendingInput = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch", role: .destructive) {
                if let code = pendingInput { model.commitInput(code) }
                pendingInput = nil
            }
            Button("Cancel", role: .cancel) { pendingInput = nil }
        } message: {
            Text("The screen will blank if nothing is attached to that input. This app cannot switch back for you if the display becomes unreachable.")
        }
    }

    var pbpRow: some View {
        Picker(selection: Binding(
            get: { model.pbpMode ?? 0 },
            set: { newValue in
                if newValue == 0 {
                    model.commitPBPMode(0)   // Off is safe — no confirmation
                } else {
                    pendingPBP = newValue
                }
            }
        )) {
            ForEach(pbpModeOptions, id: \.code) { opt in
                Text(opt.label).tag(opt.code)
            }
            if let cur = model.pbpMode, cur != 0, !pbpModeOptions.contains(where: { $0.code == cur }) {
                Text("mode \(cur)").tag(cur)
            }
        } label: {
            Label("PIP / PBP", systemImage: "rectangle.split.2x1")
                .font(.callout)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(model.ioBusy)
        .overlay(alignment: .trailing, content: {
            if let s = model.transientStatus[0xE9] { statusText(s) }
        })
        .confirmationDialog(
            "Enable \(pendingPBPLabel)?",
            isPresented: Binding(get: { pendingPBP != nil },
                                 set: { if !$0 { pendingPBP = nil } }),
            titleVisibility: .visible
        ) {
            Button("Change layout", role: .destructive) {
                if let m = pendingPBP { model.commitPBPMode(m) }
                pendingPBP = nil
            }
            Button("Cancel", role: .cancel) { pendingPBP = nil }
        } message: {
            Text("The screen layout changes immediately and the desktop re-arranges. A pane with no signal shows No Signal. Turn it back off here at any time.")
        }
    }

    var pbpInputRow: some View {
        Picker(selection: Binding(
            get: { model.pbpInput ?? -1 },
            set: { model.commitPBPInput($0) }
        )) {
            ForEach(pbpInputOptions, id: \.code) { opt in
                Text(opt.label).tag(opt.code)
            }
            if let cur = model.pbpInput, cur > 0, !pbpInputOptions.contains(where: { $0.code == cur }) {
                Text(inputCodeName(cur)).tag(cur)
            }
        } label: {
            Label("Pane input", systemImage: "rectangle.on.rectangle.slash")
                .font(.callout)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(model.ioBusy)
        .overlay(alignment: .trailing, content: {
            if let s = model.transientStatus[0xE8] { statusText(s) }
        })
    }

    var kvmRow: some View {
        HStack {
            Label("KVM", systemImage: "keyboard")
                .font(.callout)
            Spacer()
            if let s = model.transientStatus[0xE7] { statusText(s) }
            Text("0x" + String(model.kvmValue ?? 0, radix: 16))
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.tertiary)
            Button("Next") { showKVMConfirm = true }
                .controlSize(.small)
                .disabled(model.ioBusy)
        }
        .confirmationDialog(
            "Switch KVM to the next device?",
            isPresented: $showKVMConfirm,
            titleVisibility: .visible
        ) {
            Button("Switch", role: .destructive) { model.commitKVMNext() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("USB keyboard and mouse routed through this monitor follow the KVM to the next computer. Video is not affected; switch back the same way.")
        }
    }

    private var hdrRow: some View {
        Toggle(isOn: Binding(
            get: { model.hdrOn },
            set: { model.setHDR($0) }
        )) {
            Label("macOS HDR", systemImage: "sparkles")
                .font(.callout)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!model.hdrCapable || model.hdrBusy)
        .help(model.hdrCapable
              ? "While HDR is on, this monitor silently rejects brightness/contrast writes (SPEC §6)."
              : "This display does not report HDR support.")
    }

    private var lockBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Brightness locked by macOS HDR", systemImage: "lock.fill")
                .font(.callout.weight(.medium))
            Text("Writes are ACKed but silently dropped while HDR is on. Turn macOS HDR off to release the sliders.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                model.releaseLock()
            } label: {
                Label("Release (disable macOS HDR)", systemImage: "lock.open")
            }
            .controlSize(.small)
            .disabled(model.hdrBusy)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    @State private var pendingInput: Int?
    @State private var pendingPBP: Int?
    @State private var showKVMConfirm = false

    private func statusText(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.tertiary)
    }

    private var pendingPBPLabel: String {
        guard let m = pendingPBP else { return "" }
        return pbpModeOptions.first { $0.code == m }?.label ?? "mode \(m)"
    }
}

// MARK: - PIP/PBP + KVM option tables (VCP 0xE9/0xE8/0xE7, m1ddc-verified)

let pbpModeOptions: [(label: String, code: Int)] = [
    ("Off", 0),
    ("PIP small", 33),
    ("PIP large", 34),
    ("PBP 50 : 50", 36),
    ("PBP 26 : 74", 43),
    ("PBP 74 : 26", 44),
    ("PBP 2 × 2", 65),
]

let pbpInputOptions: [(label: String, code: Int)] = [
    ("DisplayPort 1", 15),
    ("DisplayPort 2", 16),
    ("HDMI 1", 17),
    ("HDMI 2", 18),
    ("HDMI 1 + 2 + DP 1", 15953),
]

// MARK: - Slider row for a VCP

struct VCPSliderRow: View {
    let model: DisplayModel
    let vcp: UInt8
    let label: String
    let icon: String

    private var state: ControlState {
        model.controls[vcp] ?? ControlState()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(state.locked ? .tertiary : .secondary)
                .help(label)
            Slider(
                value: Binding(
                    get: { Double(state.current) },
                    set: { newValue in
                        model.controls[vcp]?.current = Int(newValue)
                    }
                ),
                in: 0...Double(max(state.max, 1)),
                onEditingChanged: { editing in
                    model.controls[vcp]?.editing = editing
                    if !editing {
                        model.commit(vcp, state.current)
                    }
                }
            )
            .controlSize(.small)
            .disabled(state.locked)
            Text("\(state.current)")
                .font(.callout)
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(state.locked ? .secondary : .primary)
            ZStack {
                Text(" ").hidden()
                if state.writing {
                    ProgressView().controlSize(.mini)
                } else if !state.status.isEmpty {
                    statusView(state.status)
                }
            }
            .frame(width: 16)
        }
        .help(state.locked
              ? "\(label) — locked while macOS HDR is on; use “Release” below."
              : "\(label) — set + verified read-back (SPEC §9.3)")
    }

    @ViewBuilder
    private func statusView(_ s: String) -> some View {
        if s.hasPrefix("✓") {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .help(s)
        } else if s.hasPrefix("✗") || s.hasPrefix("locked") {
            Image(systemName: s.hasPrefix("locked") ? "lock.fill" : "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(s)
        } else {
            // energy-confirm pending / reverted outcome
            Image(systemName: s.hasPrefix("reverted") ? "exclamationmark.triangle.fill" : "hand.tap")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(s)
        }
    }
}

#Preview("Live") {
    ContentView(model: AppModel())
        .frame(width: 320)
}
