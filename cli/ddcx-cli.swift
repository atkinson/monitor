//
// ddcx — CLI front for the DDC core (Sources/DDC.swift + Sources/HDR.swift).
// Implements the SPEC §9.2 verb table and exit codes 0/1/2; protocol logic
// lives in the shared library. Built with -parse-as-library (@main), so the
// shared Sources/ tree stays free of top-level code for the GUI app.
//
// Build: make
//

import Foundation
import CoreGraphics

@main
struct DDCxCli {

    static func main() {
        guard let cmd = parsed.cmd else { print(helpText); exit(0) }
        let args = parsed.args
        let targets = DDCClient.discover(verbose: parsed.verbose)

        if cmd == "displays" {
            if targets.isEmpty { print("no external displays with DDC services discovered") }
            for (i, t) in targets.enumerated() {
                print("[\(i + 1)] \(t.name) (chip 0x\(String(t.chip, radix: 16)), uuid \(t.uuid))")
            }
            exit(0)
        }

        // Target resolution: --display N → discovered target; else first
        // discovered; else IOAVServiceCreate default (legacy single-display).
        func resolveDDC(targets: [DDCClient]) -> DDCClient {
            var client: DDCClient
            if let n = parsed.displayIndex {
                guard targets.indices.contains(n - 1) else { fail("no display #\(n) — see 'ddcx displays'", code: 2) }
                client = targets[n - 1]
            } else if let t = targets.first {
                client = t
            } else if let d = DDCClient.defaultClient() {
                client = d
            } else {
                fail("no IOAVService found — is an external display connected via USB-C/DP?")
            }
            if parsed.verbose { client.verbose = true }
            if let ms = parsed.delayOverride { client.delayMs = ms }
            if let n = parsed.triesOverride { client.maxReadAttempts = n }
            if let ck = parsed.ckOverride { client.forcedChecksum = ck }
            return client
        }
        let ddc = resolveDDC(targets: targets)

        let namedVCPs: [String: UInt8] = ["brightness": 0x10, "contrast": 0x12, "volume": 0x62]

        if let vcp = namedVCPs[cmd.lowercased()] {
            if let vStr = args.first, let v = UInt16(vStr, radix: 10) {
                runSet(ddc, vcp, v, label: cmd)
            }
            guard let r = ddc.getVCP(vcp) else { fail(ddc.lastError ?? "no valid reply for VCP 0x\(String(vcp, radix: 16))") }
            print("\(r.current)  (max \(r.max))")
            exit(0)
        }

        switch cmd {

        case "input":
            if let arg = args.first {
                let value: UInt16
                if let named = inputNames[arg.lowercased()] { value = named }
                else if let raw = parseUInt16(arg) { value = raw }
                else { fail("unknown input: \(arg)", code: 2) }
                runSet(ddc, 0x60, value, label: "input")
            }
            guard let r = ddc.getVCP(0x60) else { fail("no valid reply for VCP 0x60") }
            print("\(r.current)  (\(inputCodeName(r.current)))")
            exit(0)

        case "kvm":
            if let arg = args.first {
                let value: UInt16
                if arg == "next" { value = 0xFF00 }
                else if let v = parseUInt16(arg) { value = v }
                else { fail("bad kvm value: \(arg)", code: 2) }
                runLayoutSet(ddc, 0xE7, value, label: "kvm", command: arg == "next")
            }
            guard let r = ddc.getVCP(0xE7) else { fail("no valid reply for VCP 0xE7") }
            print("\(r.current)  (0x\(String(r.current, radix: 16)); 'kvm next' cycles USB upstream)")
            exit(0)

        case "pbp":
            if let arg = args.first {
                guard let value = pbpModes[arg.lowercased()] ?? parseUInt16(arg) else { fail("bad pbp mode: \(arg)", code: 2) }
                runLayoutSet(ddc, 0xE9, value, label: "pbp", command: false)
            }
            guard let r = ddc.getVCP(0xE9) else { fail("no valid reply for VCP 0xE9") }
            print("\(r.current)  (\(pbpModes.first { $0.value == r.current }?.key ?? "unknown"))")
            exit(0)

        case "pbp-input":
            if let arg = args.first {
                let value: UInt16
                if let named = inputNames[arg.lowercased()] { value = named }
                else if let raw = parseUInt16(arg) { value = raw }
                else { fail("bad input: \(arg)", code: 2) }
                runLayoutSet(ddc, 0xE8, value, label: "pbp-input", command: false)
            }
            guard let r = ddc.getVCP(0xE8) else { fail("no valid reply for VCP 0xE8") }
            print("\(r.current)  (\(inputCodeName(r.current)))")
            exit(0)

        case "mute":
            if let arg = args.first {
                let value: UInt16
                if arg == "on" { value = 1 }
                else if arg == "off" { value = 2 }
                else { fail("mute: on|off", code: 2) }
                runSet(ddc, 0x8D, value, label: "mute")
            }
            if let r = ddc.getVCP(0x8D) {
                print("\(r.current)  (\(r.current == 1 ? "muted" : r.current == 2 ? "unmuted" : "?"))")
            } else {
                print("no reply (mute not supported on this panel)")
            }
            exit(0)

        case "get":
            guard args.count == 1 else { fail("usage: ddcx get <vcp-hex>", code: 2) }
            let vcp = parseHex(args[0])
            guard let r = ddc.getVCP(vcp) else { fail("no valid reply for VCP 0x\(String(vcp, radix: 16)) after \(ddc.maxReadAttempts) tries") }
            print("\(r.current)  (max \(r.max), type \(String(format: "%02X", r.type)), vcp \(String(format: "0x%02X", r.vcp)) from \(ddc.name))")
            exit(0)

        case "set":
            guard args.count == 2 else { fail("usage: ddcx set <vcp-hex> <value>", code: 2) }
            let vcp = parseHex(args[0])
            guard let value = UInt16(args[1], radix: 10) else { fail("bad value: \(args[1])", code: 2) }
            runSet(ddc, vcp, value, label: "set VCP 0x\(String(vcp, radix: 16))")

        case "caps":
            guard let caps = ddc.getCaps() else { fail(ddc.lastError ?? "caps read failed") }
            print("capabilities: \(caps)")
            exit(0)

        case "watch":
            guard args.count == 2 else { fail("usage: ddcx watch <vcp-hex> <secs>", code: 2) }
            let vcp = parseHex(args[0])
            let secs = Double(args[1]) ?? 10
            print("polling VCP 0x\(String(vcp, radix: 16)) on \(ddc.name) for \(secs)s…")
            let start = Date()
            while Date().timeIntervalSince(start) < secs {
                if let r = ddc.getVCP(vcp) {
                    print(String(format: "%.1fs: %d", Date().timeIntervalSince(start), r.current))
                } else {
                    print("no valid reply")
                }
                usleep(500_000)
            }
            exit(0)

        case "raw":
            guard !args.isEmpty else { fail("usage: ddcx raw <hex bytes…>", code: 2) }
            let msg = ddc.message(args.map(parseHex))
            print("sending: \(msg.map { String(format: "%02X", $0) }.joined(separator: " "))")
            let kr = ddc.write(msg)
            print("write kr=0x\(String(kr, radix: 16))")
            for _ in 0..<6 {
                usleep(UInt32(ddc.delayMs) * 1000)
                if let b = ddc.read(count: 36) {
                    print("read (\(b.count) bytes): \(b.map { String(format: "%02X", $0) }.joined(separator: " "))")
                }
            }
            exit(0)

        case "send":
            // Verbatim post-address bytes — no framing, no checksum (diagnostics)
            guard !args.isEmpty else { fail("usage: ddcx send <hex bytes…>", code: 2) }
            let bytes = args.map(parseHex)
            let kr = ddc.write(bytes)
            print(String(format: "sent %d bytes, kr=0x%X", bytes.count, kr))
            usleep(UInt32(ddc.delayMs) * 1000)
            if let b = ddc.read(count: 36) {
                print("read: \(b.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
            exit(0)

        case "info":
            var id = CGMainDisplayID()
            for d in CGGetOnlineDisplayList() where CGDisplayIsBuiltin(d) == 0 { id = d; break }
            if let info = coreDisplayInfo(id) as? NSDictionary {
                let keys = info.allKeys.map { String(describing: $0) }.sorted()
                print("\(keys.count) keys for display \(id):")
                for k in keys {
                    let s = String(describing: info[k])
                    print("  \(k) = \(s.count > 120 ? String(s.prefix(120)) + "…" : s)")
                }
            } else {
                print("no CoreDisplay info for display \(id)")
            }
            exit(0)

        default:
            FileHandle.standardError.write("unknown command: \(cmd)\n".data(using: .utf8)!)
            print(helpText)
            exit(2)
        }
    }

    // MARK: - Set + verify tail (SPEC §9.2/§9.3 output contract)

    /// Same output and exit codes as the pre-refactor CLI: set → read-back
    /// ✓/✗ → §6.2 lock diagnostic.
    static func runSet(_ ddc: DDCClient, _ vcp: UInt8, _ value: UInt16, label: String) -> Never {
        print("sent \(label) = \(value) to \(ddc.name)")
        switch ddc.setAndVerify(vcp, value) {
        case .ok(let readBack):
            print("read-back: \(readBack) ✓")
            exit(0)
        case .writeFailed:
            fail(ddc.lastError ?? "DDC write failed")
        case .noReply:
            print("read-back: no valid reply")
            exit(1)
        case .mismatch(let readBack):
            print("read-back: \(readBack)  ✗ (value did not stick)")
            exit(1)
        case .locked(let readBack):
            print("read-back: \(readBack)  ✗ (value did not stick)")
            FileHandle.standardError.write(
                ("HDR signal lock suspected: VCP 0x\(String(vcp, radix: 16)) is locked while other codes "
                    + "still write (volume probe OK). macOS HDR is probably ON for this display — run: ./hdr off\n")
                    .data(using: .utf8)!)
            exit(1)
        }
    }

    /// Layout/USB codes (0xE7/0xE8/0xE9): writes land, but the panel goes
    /// silent on reads of the same code for ~2–4 s afterwards (observed on
    /// 0xE9 mode switches), so the §9.3 1 s verify can't apply. Write, wait
    /// out the quiet period, then read the resulting state. `command` codes
    /// (kvm next = 0xFF00) are actions, not state — the read-back is
    /// informational, exit 0.
    static func runLayoutSet(_ ddc: DDCClient, _ vcp: UInt8, _ value: UInt16, label: String, command: Bool) -> Never {
        guard ddc.setVCP(vcp, value: value) else { fail(ddc.lastError ?? "DDC write failed") }
        print("sent \(label) = \(value) to \(ddc.name)")
        sleep(3)
        guard let r = ddc.getVCP(vcp) else {
            print("read-back: no valid reply after 2 s (write may still have landed — re-query later)")
            exit(1)
        }
        if command {
            print("read-back: \(r.current)  (0x\(String(r.current, radix: 16)))")
            exit(0)
        }
        let ok = r.current == Int(value)
        print("read-back: \(r.current)\(ok ? " ✓" : "  ✗ (code now \(r.current))")")
        exit(ok ? 0 : 1)
    }
}

// MARK: - Argument parsing

private struct ParsedArgs {
    var cmd: String?
    var args: [String] = []
    var verbose = false
    var displayIndex: Int?
    var delayOverride: Int?
    var triesOverride: Int?
    var ckOverride: UInt8?
}

private let parsed: ParsedArgs = {
    var p = ParsedArgs()
    var args = Array(CommandLine.arguments.dropFirst())
    if let i = args.firstIndex(of: "-v") { p.verbose = true; args.remove(at: i) }
    if let i = args.firstIndex(of: "--delay"), i + 1 < args.count { p.delayOverride = Int(args[i+1]) ?? 40; args.remove(at: i+1); args.remove(at: i) }
    if let i = args.firstIndex(of: "--tries"), i + 1 < args.count { p.triesOverride = Int(args[i+1]) ?? 15; args.remove(at: i+1); args.remove(at: i) }
    if let i = args.firstIndex(of: "--ck"), i + 1 < args.count { p.ckOverride = parseHex(args[i+1]); args.remove(at: i+1); args.remove(at: i) }
    if let i = args.firstIndex(of: "--display"), i + 1 < args.count { p.displayIndex = Int(args[i+1]); args.remove(at: i+1); args.remove(at: i) }
    p.cmd = args.first
    if !args.isEmpty { args.removeFirst() }
    p.args = args
    return p
}()

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

private let helpText = """
ddcx — validated DDC/CI control for Apple Silicon Macs (see SPEC.md)

Usage:
  ddcx displays                    List DDC-capable external displays
  ddcx brightness|contrast|volume [n]   Get (no arg) or set + verify
  ddcx input [dp1|dp2|hdmi1|hdmi2|usb-c|code]
  ddcx mute [on|off]
  ddcx kvm [next|raw]              Dell KVM control (VCP 0xE7)
  ddcx pbp [off|small|large|5050|2674|7426|2x2|raw]
  ddcx pbp-input <dp1|dp2|hdmi1|hdmi2>
  ddcx get|set <vcp-hex> [value]   Raw VCP access (checksum-validated)
  ddcx caps | watch <vcp> <secs> | info
  ddcx raw|send <hex bytes…>       Diagnostics (send = verbatim bytes)

Options:
  -v             verbose hex dumps to stderr
  --display N    target display number (see 'displays')
  --delay N      inter-operation delay ms (default 40)
  --tries N      max read attempts (default 15)
  --ck XX        force checksum byte (protocol experiments)

Exit codes: 0 ok · 1 failure · 2 usage.
Note: while macOS HDR is ON, brightness/contrast/preset writes are accepted
at the bus level but silently dropped by the monitor — ddcx detects this and
suggests './hdr off' (see SPEC.md §6).
"""

func parseUInt16(_ s: String) -> UInt16? {
    let t = s.lowercased()
    if t.hasPrefix("0x") { return UInt16(t.dropFirst(2), radix: 16) }
    return UInt16(t, radix: 10)
}

func parseHex(_ s: String) -> UInt8 {
    let t = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    guard let v = UInt8(t, radix: 16) else { fail("bad hex byte: \(s)", code: 2) }
    return v
}

let pbpModes: [String: UInt16] = ["off": 0, "small": 33, "large": 34, "5050": 36,
                                  "2674": 43, "7426": 44, "2x2": 65]
