import AppKit
import IOKit
import IOKit.ps

/// A live reading of the internal battery, straight from the power-source API.
struct BatteryReading {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool

    static func current() -> BatteryReading? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let d = IOPSGetPowerSourceDescription(snap, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return BatteryReading(
                percent: Int((Double(cur) / Double(max) * 100).rounded()),
                isCharging: d[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }
}

/// How much energy a full charge of this battery holds, in watt-hours.
///
/// The Battery tab turns an app's share of measured chip power into PERCENTAGE
/// POINTS OF BATTERY, which is the only unit in that table a reader can compare
/// to anything -- the column beside it is already in points. Converting watt-
/// hours to points needs this number, and it has to come from the machine: a
/// hardcoded capacity would be wrong on every other Mac and wrong on this one
/// after the battery ages. Health is already 83% here, which is 17% of the
/// answer.
///
/// `AppleRawMaxCapacity` is the charge the battery actually holds today, in mAh,
/// and it is the right one -- `DesignCapacity` describes the battery when it was
/// new and `MaxCapacity` on modern macOS is just the number 100.
///
/// The voltage is the instantaneous pack voltage, which swings roughly 11.1-12.7V
/// between empty and charging, so this figure carries about +/-10%. That is
/// acceptable for what it is used for -- scaling an attribution that is itself an
/// estimate -- and it is why the tab shows one decimal place and not three.
enum BatteryCapacity {

    /// nil when there is no internal battery, or IOKit will not answer.
    static func fullChargeWh() -> Double? {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any],
              let mAh = d["AppleRawMaxCapacity"] as? Int,
              let mV = d["Voltage"] as? Int,
              mAh > 0, mV > 0
        else { return nil }

        return Double(mAh) * Double(mV) / 1_000_000
    }

    /// Watt-hours per percentage point of charge.
    static func whPerPoint() -> Double? {
        fullChargeWh().map { $0 / 100 }
    }
}

/// Draws the menu-bar glyph: the same rounded shell + nub + proportional fill the
/// system indicator uses, so the two sit next to each other without clashing.
///
/// Returned as a template image (it tints itself for light/dark and for the
/// highlighted menu-bar state) EXCEPT when low or charging, where the colour is
/// the whole point and a template would throw it away.
enum BatteryIcon {
    static func image(percent: Int, charging: Bool, onAC: Bool) -> NSImage {
        let w: CGFloat = 25, h: CGFloat = 12
        let bodyW = w - 2.5                    // leave room for the terminal nub
        let lineW: CGFloat = 1.0
        let low = percent <= 20 && !charging && !onAC

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let shell = NSRect(x: lineW / 2, y: lineW / 2 + 0.5,
                               width: bodyW - lineW, height: h - lineW - 1)
            let outline = NSBezierPath(roundedRect: shell, xRadius: 3.2, yRadius: 3.2)
            outline.lineWidth = lineW
            (low ? NSColor.systemRed : NSColor.black).withAlphaComponent(low ? 0.9 : 0.45).setStroke()
            outline.stroke()

            // terminal nub
            let nub = NSBezierPath(roundedRect: NSRect(x: bodyW + 0.3, y: h / 2 - 2.0,
                                                       width: 1.6, height: 4.0),
                                   xRadius: 0.8, yRadius: 0.8)
            (low ? NSColor.systemRed : NSColor.black).withAlphaComponent(low ? 0.9 : 0.45).setFill()
            nub.fill()

            // proportional fill
            let inset = shell.insetBy(dx: 1.6, dy: 1.6)
            let frac = CGFloat(min(max(percent, 0), 100)) / 100
            if frac > 0 {
                let fillW = max(inset.width * frac, 2.0)
                let fill = NSBezierPath(
                    roundedRect: NSRect(x: inset.minX, y: inset.minY,
                                        width: fillW, height: inset.height),
                    xRadius: 1.6, yRadius: 1.6)
                if low { NSColor.systemRed.setFill() }
                else if charging { NSColor.systemGreen.setFill() }
                else { NSColor.black.setFill() }
                fill.fill()
            }

            if charging {   // bolt, punched out of the fill
                let bolt = NSBezierPath()
                let cx = bodyW / 2, cy = h / 2
                bolt.move(to: NSPoint(x: cx + 1.3, y: cy + 3.6))
                bolt.line(to: NSPoint(x: cx - 2.3, y: cy - 0.2))
                bolt.line(to: NSPoint(x: cx - 0.2, y: cy - 0.2))
                bolt.line(to: NSPoint(x: cx - 1.3, y: cy - 3.6))
                bolt.line(to: NSPoint(x: cx + 2.4, y: cy + 0.3))
                bolt.line(to: NSPoint(x: cx + 0.3, y: cy + 0.3))
                bolt.close()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSColor.black.setFill()
                bolt.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        img.isTemplate = !low && !charging
        return img
    }
}

/// Battery condition, as System Settings reports it.
///
/// Maximum Capacity is NOT a ratio you can compute from ioreg: 7302/8694 and
/// 7546/8694 both miss the 83% macOS shows, because macOS smooths it. The only
/// figure that matches the one the user can check is the one system_profiler
/// prints -- and with -json it costs ~0.15s, so there is no reason to guess.
struct BatteryHealth {
    var maximumCapacity: String      // "83%"
    var cycleCount: Int
    var condition: String            // "Good", "Service Recommended", ...

    static func read() -> BatteryHealth? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let h = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            return BatteryHealth(
                maximumCapacity: h["sppower_battery_health_maximum_capacity"] as? String ?? "—",
                cycleCount: h["sppower_battery_cycle_count"] as? Int ?? 0,
                condition: h["sppower_battery_health"] as? String ?? "—")
        }
        return nil
    }
}
