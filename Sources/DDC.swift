//
// DDC — DDC/CI core for external displays on Apple Silicon.
// Implements SPEC.md L1–L4 (transport, framing, commands, VCP registry),
// the §6.2 lock heuristic, and §8 display discovery, as a library shared
// by the ddcx CLI and the Monitor GUI app.
//
// All I/O here is blocking and usleep-paced (SPEC §2.3). Never call from a
// main/UI thread; the app wraps this in a background actor.
//

import Foundation
import IOKit
import CoreGraphics

// MARK: - Semi-private IOAVService API (not in public SDK headers)

private let iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

private typealias IOAVServiceCreateFn = @convention(c) (CFAllocator?) -> CFTypeRef?
private typealias IOAVServiceCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> CFTypeRef?
private typealias IOAVServiceReadI2CFn = @convention(c) (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> kern_return_t
private typealias IOAVServiceWriteI2CFn = @convention(c) (CFTypeRef?, UInt32, UInt32, UnsafeRawPointer, UInt32) -> kern_return_t

private func sym<T>(_ name: String) -> T? {
    iokitHandle.flatMap { h in dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
}
private let IOAVServiceCreate: IOAVServiceCreateFn? = sym("IOAVServiceCreate")
private let IOAVServiceCreateWithService: IOAVServiceCreateWithServiceFn? = sym("IOAVServiceCreateWithService")
private let IOAVServiceReadI2C: IOAVServiceReadI2CFn? = sym("IOAVServiceReadI2C")
private let IOAVServiceWriteI2C: IOAVServiceWriteI2CFn? = sym("IOAVServiceWriteI2C")

// MARK: - DDC/CI constants (SPEC §2, §3)

let dataAddress: UInt32 = 0x51      // "source address" first byte / I2C offset
let opGetVCP: UInt8 = 0x01
let opSetVCP: UInt8 = 0x03
let opGetCaps: UInt8 = 0xF3

/// Checksum over message bytes, m1ddc law (VERIFIED: volume writes with it
/// land and persist). NOTE the monitor's own replies use a different law —
/// XOR of all reply bytes incl. checksum == 0x50 — see parse/validate below.
func checksum(_ bytes: [UInt8]) -> UInt8 {
    bytes.reduce(0x6E ^ 0x51) { $0 ^ $1 }
}

// MARK: - Reply parsing (SPEC §4.1)

struct VCPReply {
    let vcp: UInt8
    let type: UInt8
    let max: Int
    let current: Int
    let raw: [UInt8]
}

/// U4025QW Get VCP reply (11 bytes):
/// [0]6E [1]80|len [2]02 [3]00 [4]vcp [5]type [6,7]max BE [8,9]cur BE [10]ck
func parseVCPReply(_ msg: [UInt8]) -> VCPReply? {
    guard msg.count >= 11, msg[0] == 0x6E, msg[2] == 0x02 else { return nil }
    return VCPReply(vcp: msg[4], type: msg[5],
                    max: Int(msg[6]) << 8 | Int(msg[7]),
                    current: Int(msg[8]) << 8 | Int(msg[9]),
                    raw: msg)
}

/// Outcome of a set + verify cycle (SPEC §9.3). `.locked` means the §6.2
/// volume probe confirmed the HDR signal lock — callers should offer
/// "release (disable macOS HDR)" rather than retry.
enum SetResult {
    case ok(readBack: Int)
    case writeFailed       // transport-level failure; see lastError
    case noReply           // verify read timed out
    case mismatch(readBack: Int)
    case locked(readBack: Int)
}

/// One external display's DDC/CI connection.
final class DDCClient {
    let name: String
    let uuid: String
    let service: CFTypeRef
    let chip: UInt32

    /// Tunables (SPEC §2.3, §7.2); defaults are the verified-good values.
    var delayMs = 40
    var maxReadAttempts = 15
    var forcedChecksum: UInt8?
    var verbose = false

    /// Transport-level failure text for the last failed operation.
    private(set) var lastError: String?

    init(name: String, uuid: String, service: CFTypeRef, chip: UInt32) {
        self.name = name
        self.uuid = uuid
        self.service = service
        self.chip = chip
    }

    func logv(_ s: @autoclosure () -> String) {
        if verbose { FileHandle.standardError.write(("[" + s() + "]\n").data(using: .utf8)!) }
    }

    // MARK: Framing (SPEC §3)

    /// Build a message: [0x80 | payloadLen] + payload + checksum.
    func message(_ payload: [UInt8]) -> [UInt8] {
        var m = [UInt8(0x80 | payload.count)] + payload
        m.append(forcedChecksum ?? checksum(m))
        return m
    }

    // MARK: Transport (SPEC §2, §7)

    func write(_ bytes: [UInt8]) -> kern_return_t {
        bytes.withUnsafeBufferPointer { buf in
            IOAVServiceWriteI2C!(service, chip, dataAddress, buf.baseAddress!, UInt32(bytes.count))
        }
    }

    /// Raw read of `count` bytes; nil on transport error or all-zero buffer.
    /// Replies arrive misaligned and may split across reads (SPEC §7.1) —
    /// callers must scan a rolling stream, never trust offsets.
    func read(count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        let kr = buf.withUnsafeMutableBufferPointer { p in
            IOAVServiceReadI2C!(service, chip, dataAddress, p.baseAddress!, UInt32(count))
        }
        guard kr == KERN_SUCCESS else {
            logv("read kr=0x\(String(kr, radix: 16))")
            return nil
        }
        guard buf.contains(where: { $0 != 0 }) else { return nil }
        return buf
    }

    /// SPEC §7.2 parser: accumulate reads into a stream, scan for
    /// [0x6E][0x80|len][opcode]…[checksum] with XOR-all == 0x50.
    func readMessage(opcode: UInt8, vcp: UInt8? = nil, readSize: Int = 36, maxReads: Int = 20) -> [UInt8]? {
        var stream = [UInt8]()
        for _ in 0..<maxReads {
            usleep(UInt32(delayMs) * 1000)
            if let chunk = read(count: readSize) { stream += chunk }
            if stream.count >= 11 {
                var i = 0
                while i + 3 <= stream.count {
                    let plen = Int(stream[i + 1] & 0x7F)
                    let end = i + 2 + plen       // index of checksum byte
                    if stream[i] == 0x6E, (stream[i + 1] & 0x80) != 0, stream[i + 2] == opcode,
                       end < stream.count, plen >= 6 {
                        let msg = Array(stream[i...end])
                        if msg.reduce(UInt8(0)) { $0 ^ $1 } == 0x50 {
                            if let v = vcp, msg[4] != v {
                                i += 1
                                continue   // valid but stale reply for another VCP
                            }
                            logv("matched: \(msg.map { String(format: "%02X", $0) }.joined(separator: " "))")
                            return msg
                        }
                    }
                    i += 1
                }
            }
        }
        return nil
    }

    // MARK: Validated operations (SPEC §4, §7.3)

    func getVCP(_ vcp: UInt8) -> VCPReply? {
        lastError = nil
        _ = read(count: 36)   // nudge stale reply buffer
        usleep(UInt32(delayMs) * 1000)
        let query = message([opGetVCP, vcp])
        guard write(query) == KERN_SUCCESS else {
            lastError = "DDC write failed (query VCP 0x\(String(vcp, radix: 16)))"
            return nil
        }
        guard let msg = readMessage(opcode: 0x02, vcp: vcp) else { return nil }
        return parseVCPReply(msg)
    }

    /// Send the set frame `writes` times, 40 ms apart (SPEC §7.3).
    /// Returns false only on transport-level failure (see lastError);
    /// transport ACK still does NOT mean the monitor applied the value.
    @discardableResult
    func setVCP(_ vcp: UInt8, value: UInt16, writes: Int = 2) -> Bool {
        lastError = nil
        let hi = UInt8(value >> 8), lo = UInt8(value & 0xFF)
        let msg = message([opSetVCP, vcp, hi, lo])
        for _ in 0..<max(1, writes) {
            usleep(UInt32(delayMs) * 1000)
            let kr = write(msg)
            guard kr == KERN_SUCCESS else {
                lastError = String(format: "DDC write failed (set VCP 0x%02X = %d), kr=0x%X", vcp, value, kr)
                return false
            }
        }
        return true
    }

    /// SPEC §4.2: caps string in depth-tracked chunks; firmware string is
    /// mangled/truncated — output is a hint, never truth.
    func getCaps() -> String? {
        lastError = nil
        var result = ""
        var offset = 0
        let maxLen = 2048
        var depth = 0
        var opened = false
        while result.count < maxLen {
            let hi = UInt8(offset >> 8), lo = UInt8(offset & 0xFF)
            let query = message([opGetCaps, hi, lo])
            guard write(query) == KERN_SUCCESS else {
                lastError = "DDC write failed (caps at offset \(offset))"
                return nil
            }
            guard let msg = readMessage(opcode: 0xE3, maxReads: 12) else {
                lastError = "caps read failed at offset \(offset)"
                return nil
            }
            let plen = Int(msg[1] & 0x7F)
            guard plen >= 2, msg.count >= 2 + plen + 1 else { break }
            let payload = msg[3..<(3 + plen)]
            let chunk = String(bytes: payload, encoding: .ascii) ?? ""
            if chunk.isEmpty { break }
            result += chunk
            for c in chunk {
                if c == "(" { depth += 1; opened = true }
                if c == ")" { depth -= 1 }
            }
            if opened && depth <= 0 { break }          // outer parens closed
            offset += payload.count
        }
        return result
    }

    /// SPEC §9.3 write-verify: set, ≥1 s settle, validated read-back; on
    /// mismatch run the §6.2 lock heuristic. Blocking — off the main thread.
    func setAndVerify(_ vcp: UInt8, _ value: UInt16) -> SetResult {
        guard setVCP(vcp, value: value) else { return .writeFailed }
        sleep(1)
        guard let r = getVCP(vcp) else { return .noReply }
        if r.current == Int(value) { return .ok(readBack: r.current) }
        return diagnoseLock(failedVCP: vcp)
            ? .locked(readBack: r.current)
            : .mismatch(readBack: r.current)
    }

    /// SPEC §6.2: after a set that didn't stick, probe whether the write
    /// path itself works by toggling volume by one step and back. If volume
    /// responds, the bus and framing are fine and the mismatch is the HDR
    /// signal lock. Returns true when the lock is suspected.
    ///
    /// Scope: only the verified HDR lock set (0x10/0x12/0xDC). Layout/USB
    /// codes 0xE7–0xE9 can mismatch for an unrelated reason — the panel
    /// stonewalls reads on those codes for ~1–2 s after a write — and the
    /// probe false-positived on 0xE8 (observed 2026-10-16, HDR off).
    @discardableResult
    func diagnoseLock(failedVCP: UInt8) -> Bool {
        guard failedVCP == 0x10 || failedVCP == 0x12 || failedVCP == 0xDC else { return false }
        guard let cur = getVCP(0x62) else { return false }
        let probeValue = cur.current >= cur.max ? cur.current - 1 : cur.current + 1
        setVCP(0x62, value: UInt16(probeValue), writes: 1)
        usleep(500_000)
        guard let after = getVCP(0x62), after.current == probeValue else { return false }
        setVCP(0x62, value: UInt16(cur.current), writes: 1)
        return true
    }
}

// MARK: - Display discovery (SPEC §8)

private var discoveryVerbose = false
private func dlog(_ s: String) {
    if discoveryVerbose { FileHandle.standardError.write(("[" + s + "]\n").data(using: .utf8)!) }
}

private func regSearch(_ service: io_service_t, _ key: String) -> CFTypeRef? {
    IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                    kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
}

private func isMCDP29xx(_ service: io_service_t) -> Bool {
    var parent: io_service_t = 0
    guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(parent) }
    let cls = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    return (cls as? String) == "AppleDCPMCDP29XX"
}

/// Find the external DCPAVServiceProxy under the framebuffer whose registry
/// entry ID matches `framebufferID` (m1ddc's proven correlation walk).
private func findExternalAVService(framebufferID: UInt64) -> (CFTypeRef, UInt32)? {
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard root != 0 else { return nil }
    var iter: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else {
        IOObjectRelease(root)
        return nil
    }
    defer { IOObjectRelease(iter); IOObjectRelease(root) }

    var inFramebuffer = false
    while true {
        let service = IOIteratorNext(iter)
        guard service != 0 else { break }
        defer { IOObjectRelease(service) }

        if IOObjectConformsTo(service, "IOMobileFramebuffer") != 0 {
            var fid: UInt64 = 0
            inFramebuffer = IORegistryEntryGetRegistryEntryID(service, &fid) == KERN_SUCCESS && fid == framebufferID
            var nb = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &nb)
            dlog("framebuffer \(String(cString: nb)) id=\(fid) match=\(inFramebuffer)")
            continue
        }
        guard inFramebuffer else { continue }
        var nameBuf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(service, &nameBuf) == KERN_SUCCESS, String(cString: nameBuf) == "DCPAVServiceProxy" else { continue }
        guard let loc = regSearch(service, "Location") as? String, loc == "External" else {
            dlog("DCPAVServiceProxy found but Location=\(regSearch(service, "Location") ?? "nil" as CFTypeRef)")
            continue
        }
        guard let av = IOAVServiceCreateWithService?(kCFAllocatorDefault, service) else { return nil }
        return (av, isMCDP29xx(service) ? 0xB7 : 0x37)
    }
    dlog("registry walk exhausted without a matching external DCPAVServiceProxy")
    return nil
}

/// Semi-private CoreDisplay symbol. The on-disk private framework is a
/// stub on modern macOS, so dlsym on its handle fails in a compiled binary;
/// resolve via RTLD_DEFAULT (-2) — CoreDisplay is already loaded by CoreGraphics.
func coreDisplayInfo(_ id: CGDirectDisplayID) -> CFDictionary? {
    typealias Fn = @convention(c) (CGDirectDisplayID) -> CFDictionary?
    guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
    return unsafeBitCast(f, to: Fn.self)(id)
}

func CGGetOnlineDisplayList() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return Array(ids[0..<Int(count)])
}

extension DDCClient {

    /// Registry walk per SPEC §8: CG online displays → IODisplayLocation →
    /// matching framebuffer's external DCPAVServiceProxy.
    static func discover(verbose: Bool = false) -> [DDCClient] {
        discoveryVerbose = verbose
        defer { discoveryVerbose = false }
        var clients: [DDCClient] = []
        for id in CGGetOnlineDisplayList() where CGDisplayIsBuiltin(id) == 0 {
            guard let info = coreDisplayInfo(id) as? NSDictionary else {
                dlog("display \(id): no CoreDisplay info dict")
                continue
            }
            guard let ioLocation = info["IODisplayLocation"] as? String else {
                dlog("display \(id): no IODisplayLocation (virtual display?)")
                continue
            }
            let uuid = info["kCGDisplayUUID"] as? String ?? ""
            let adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, ioLocation as CFString)
            guard adapter != 0 else { continue }
            defer { IOObjectRelease(adapter) }

            var name = "Display"
            if let attrs = regSearch(adapter, "DisplayAttributes") as? [String: Any],
               let product = attrs["ProductAttributes"] as? [String: Any],
               let pn = product["ProductName"] as? String, !pn.isEmpty { name = pn }

            var adapterID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(adapter, &adapterID) == KERN_SUCCESS,
                  let (service, chip) = findExternalAVService(framebufferID: adapterID) else { continue }
            let client = DDCClient(name: name, uuid: uuid, service: service, chip: chip)
            client.verbose = verbose
            clients.append(client)
        }
        return clients
    }

    /// Legacy single-display fallback: IOAVServiceCreate's default service.
    static func defaultClient() -> DDCClient? {
        guard let s = IOAVServiceCreate?(kCFAllocatorDefault) else { return nil }
        return DDCClient(name: monitorPanelName(), uuid: "", service: s, chip: 0x37)
    }
}

/// MonitorPanel name fallback when registry discovery fails.
func monitorPanelName() -> String {
    if let bundle = Bundle(path: "/System/Library/PrivateFrameworks/MonitorPanel.framework"),
       bundle.load(),
       let mgrClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type,
       let mgr = mgrClass.perform(NSSelectorFromString("sharedMgr"))?.takeUnretainedValue() as? NSObject,
       let displays = mgr.value(forKey: "displays") as? [NSObject] {
        let external = displays.filter { !(($0.value(forKey: "isBuiltIn") as? NSNumber)?.boolValue ?? true) }
        if let d = external.first ?? displays.first,
           let name = d.value(forKey: "displayName") as? String {
            return name
        }
    }
    return "display"
}

// MARK: - Input codes (SPEC §5)

// 0x19 (25) is this panel's live USB-C code (verified via get 0x60 → 0x1919
// and its own caps `60(19 0F 11)`); 27 is the MCCS standard code.
let inputNames: [String: UInt16] = ["dp1": 15, "dp2": 16, "hdmi1": 17, "hdmi2": 18,
                                    "usb-c": 25, "usbc": 25, "type-c": 25]

func inputCodeName(_ code: Int) -> String {
    // VCP 0x60 reads as 16-bit (e.g. 0x1919); the meaningful code is the low byte
    switch code & 0xFF {
    case 15: return "dp1"
    case 16: return "dp2"
    case 17: return "hdmi1"
    case 18: return "hdmi2"
    case 25: return "usb-c (Dell 0x19)"
    case 27: return "usb-c"
    case 15953: return "hdmi1 + hdmi2 + dp1 (PBP combo)"
    default: return String(format: "code 0x%02X", code)
    }
}

/// Entries for the GUI input picker (VCP 0x60). USB-C appears twice: this
/// Dell reports 0x19, the MCCS standard says 0x1B — panels vary, so both
/// are offered. Never auto-switch — writing 0x60 blanks the only display
/// (SPEC hard constraint).
let pickerInputs: [(label: String, code: UInt16)] = [
    ("DisplayPort 1", 15),
    ("DisplayPort 2", 16),
    ("HDMI 1", 17),
    ("HDMI 2", 18),
    ("USB-C (0x19)", 25),
    ("USB-C (0x1B)", 27),
]
