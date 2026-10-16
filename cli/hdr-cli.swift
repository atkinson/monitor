//
// hdr — CLI front for HDRControl (Sources/HDR.swift): read/toggle macOS HDR
// (preferHDRModes) for displays, the same mechanism System Settings uses.
// Built with -parse-as-library (@main).
//
// Usage: hdr          show HDR state per display
//        hdr off      turn HDR off (all HDR-capable externals)
//        hdr on       turn HDR on
//

import Foundation

@main
struct HDRCli {

    static func main() {
        guard let displays = HDRControl.displays() else {
            FileHandle.standardError.write("MonitorPanel.framework unavailable\n".data(using: .utf8)!)
            exit(1)
        }

        let arg = CommandLine.arguments.dropFirst().first?.lowercased()
        let target: Bool? = arg == "on" ? true : arg == "off" ? false : nil

        var acted = false
        for d in displays {
            let label = "\(d.name)\(d.isBuiltIn ? " [built-in]" : "")"
            if target == nil {
                print("\(label): HDR \(d.prefersHDR ? "ON" : "off")\(d.isHDRCapable ? "" : " (not HDR-capable)")")
                continue
            }
            guard d.isHDRCapable, !d.isBuiltIn, d.prefersHDR != target! else { continue }
            let before = d.prefersHDR
            guard let now = HDRControl.setPrefersHDR(target!, for: d) else { continue }
            print("\(label): HDR \(before ? "ON" : "off") → \(now ? "ON" : "off")")
            acted = true
        }

        if target != nil && !acted {
            print("nothing to do (already in requested state, or not HDR-capable)")
            exit(0)
        }
    }
}
