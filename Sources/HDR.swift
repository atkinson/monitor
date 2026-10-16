//
// HDR — read/toggle macOS HDR (preferHDRModes) per display via the private
// MonitorPanel framework (the same mechanism System Settings uses), SPEC §6.3.
// Shared by the hdr CLI and the Monitor GUI app.
//
// MonitorPanel is ObjC: load the bundle at runtime, use KVC — no headers needed.
//

import Foundation

enum HDRControl {

    struct Display {
        let object: NSObject
        let name: String
        let isBuiltIn: Bool
        let isHDRCapable: Bool
        var prefersHDR: Bool
    }

    private static func sharedMgr() -> NSObject? {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/MonitorPanel.framework"),
              bundle.load(),
              let mgrClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        return mgrClass.perform(NSSelectorFromString("sharedMgr"))?.takeUnretainedValue() as? NSObject
    }

    /// All displays known to MonitorPanel; nil if the framework is unavailable.
    static func displays() -> [Display]? {
        guard let mgr = sharedMgr(),
              let list = mgr.value(forKey: "displays") as? [NSObject] else { return nil }
        return list.map { d in
            Display(object: d,
                    name: (d.value(forKey: "displayName") as? String) ?? "?",
                    isBuiltIn: (d.value(forKey: "isBuiltIn") as? NSNumber)?.boolValue ?? false,
                    isHDRCapable: (d.value(forKey: "hasHDRModes") as? NSNumber)?.boolValue ?? false,
                    prefersHDR: (d.value(forKey: "preferHDRModes") as? NSNumber)?.boolValue ?? false)
        }
    }

    /// Flip preferHDRModes for one display and read it back after a settle.
    /// Returns the confirmed new state, or nil if the write didn't take.
    @discardableResult
    static func setPrefersHDR(_ on: Bool, for display: Display) -> Bool? {
        display.object.setValue(NSNumber(value: on), forKey: "preferHDRModes")
        usleep(400_000)
        let now = (display.object.value(forKey: "preferHDRModes") as? NSNumber)?.boolValue ?? false
        return now == on ? now : nil
    }
}
