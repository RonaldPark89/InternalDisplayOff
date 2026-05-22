import Foundation
import IOKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InternalDisplayOff", category: "Brightness")

final class BrightnessController {
    static let shared = BrightnessController()

    private typealias DSGetFn   = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSetFn   = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias AVNewFn   = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias AVWriteFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, Int) -> IOReturn
    private typealias AVReadFn  = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, Int) -> IOReturn

    private let dsLib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private let ioLib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private lazy var dsGet:  DSGetFn?  = sym("DisplayServicesGetBrightness", from: dsLib)
    private lazy var dsSet:  DSSetFn?  = sym("DisplayServicesSetBrightness", from: dsLib)
    private lazy var avNew:  AVNewFn?  = sym("IOAVServiceCreateWithService", from: ioLib)
                                      ?? sym("IOAVServiceCreateWithService", from: nil)
    private lazy var avWrite: AVWriteFn? = sym("IOAVServiceWriteI2C", from: ioLib)
                                        ?? sym("IOAVServiceWriteI2C", from: nil)
    private lazy var avRead:  AVReadFn?  = sym("IOAVServiceReadI2C",  from: ioLib)
                                        ?? sym("IOAVServiceReadI2C",  from: nil)

    private func sym<T>(_ name: String, from handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let s = dlsym(handle, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    // Discovered IOAVService refs from DCPAVServiceProxy (one per physical port with a display).
    // Stored as raw pointers; owned via Create Rule — intentionally not released (app lifetime).
    private var avServices: [UnsafeMutableRawPointer]? = nil
    private var dsCapable: [CGDirectDisplayID: Bool] = [:]
    private let queue = DispatchQueue(label: "com.internalDisplayOff.brightness", qos: .userInteractive)

    private init() {}

    // MARK: - Public

    /// Adjusts brightness on all enabled external displays by one step.
    func adjustAllExternalBrightness(increase: Bool) {
        let externals = DisplayManager.shared.displays.filter { !$0.isBuiltin && $0.isEnabled }
        queue.async { [self] in
            var anyNeedsDDC = false
            for d in externals {
                if !tryDisplayServices(d.id, increase: increase) { anyNeedsDDC = true }
            }
            // DDC path for non-Apple / non-DisplayServices monitors
            if anyNeedsDDC {
                for svc in discoverAVServices() { tryDDC(svc, increase: increase) }
            }
        }
    }

    func invalidateCache() {
        queue.async { [self] in
            avServices = nil
            dsCapable.removeAll()
        }
    }

    // MARK: - DisplayServices (Apple Studio Display, Pro Display XDR, some USB-C monitors)

    private func tryDisplayServices(_ id: CGDirectDisplayID, increase: Bool) -> Bool {
        guard let get = dsGet, let set = dsSet else { return false }
        if dsCapable[id] == false { return false }

        var current: Float = 0
        guard get(id, &current) == 0 else { dsCapable[id] = false; return false }
        dsCapable[id] = true
        let newVal = max(0, min(1, current + (increase ? 1.0/16.0 : -1.0/16.0)))
        _ = set(id, newVal)
        logger.debug("DS brightness \(current) → \(newVal) on display \(id)")
        return true
    }

    // MARK: - DDC/CI via IOAVService (Apple Silicon, third-party monitors)

    private func tryDDC(_ svc: UnsafeMutableRawPointer, increase: Bool) {
        guard let (cur, maxVal) = ddcGet(svc) else { return }
        let step = Swift.max(1, maxVal / 16)
        let newVal = increase ? Swift.min(maxVal, cur + step) : Swift.max(0, cur - step)
        ddcSet(svc, value: newVal)
        logger.debug("DDC brightness \(cur)/\(maxVal) → \(newVal)")
    }

    // MARK: - DCPAVServiceProxy discovery (Apple Silicon display port services)

    private func discoverAVServices() -> [UnsafeMutableRawPointer] {
        if let cached = avServices { return cached }

        guard let create = avNew else { avServices = []; return [] }

        var result: [UnsafeMutableRawPointer] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
              IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else {
            avServices = []
            return []
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            if let svc = create(kCFAllocatorDefault, service) {
                result.append(svc)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }

        logger.info("Discovered \(result.count) DCPAVServiceProxy service(s)")
        avServices = result
        return result
    }

    // MARK: - DDC/CI protocol (VESA standard, VCP code 0x10 = luminance)

    private static let vcpBrightness: UInt8 = 0x10
    // Checksum: XOR of dest I2C addr (0x6E = 0x37<<1), src addr (0x51), and all message bytes
    private func ddcChecksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
    }

    private func ddcGet(_ svc: UnsafeMutableRawPointer) -> (current: Int, max: Int)? {
        guard let write = avWrite, let read = avRead else { return nil }
        let vcp = Self.vcpBrightness

        var req: [UInt8] = [0x82, 0x01, vcp, 0x00]
        req[3] = ddcChecksum([0x82, 0x01, vcp])
        let reqLen = req.count
        let writeOK = req.withUnsafeMutableBytes {
            write(svc, 0x37, 0x51, $0.baseAddress!, reqLen)
        } == kIOReturnSuccess
        guard writeOK else { return nil }

        usleep(50_000)  // DDC/CI spec requires ≥40 ms between request and read

        var resp = [UInt8](repeating: 0, count: 11)
        let respLen = resp.count
        let readOK = resp.withUnsafeMutableBytes {
            read(svc, 0x37, 0x6E, $0.baseAddress!, respLen)
        } == kIOReturnSuccess
        guard readOK else { return nil }

        // Layout: [srcAddr(0x6E)?, lengthFlags, replyCmd(0x02), errCode, vcpCode, type, maxHi, maxLo, curHi, curLo, checksum]
        let b = resp[0] == 0x6E ? 1 : 0
        guard resp.count > b + 9,
              resp[b + 1] == 0x02, resp[b + 2] == 0x00, resp[b + 3] == vcp else { return nil }

        let maxVal = (Int(resp[b + 5]) << 8) | Int(resp[b + 6])
        let curVal = (Int(resp[b + 7]) << 8) | Int(resp[b + 8])
        return (curVal, maxVal > 0 ? maxVal : 100)
    }

    private func ddcSet(_ svc: UnsafeMutableRawPointer, value: Int) {
        guard let write = avWrite else { return }
        let vcp = Self.vcpBrightness
        let hi = UInt8(value >> 8)
        let lo = UInt8(value & 0xFF)
        var req: [UInt8] = [0x84, 0x03, vcp, hi, lo, 0x00]
        req[5] = ddcChecksum([0x84, 0x03, vcp, hi, lo])
        let reqLen = req.count
        _ = req.withUnsafeMutableBytes { write(svc, 0x37, 0x51, $0.baseAddress!, reqLen) }
    }
}
