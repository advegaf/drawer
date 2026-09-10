import AppKit
import CoreGraphics
import Foundation

// Everything in this file calls undocumented, private macOS symbols:
// IOBluetooth's power preference functions, DisplayServices' brightness
// functions, login's lock-screen function, and CoreBrightness's
// CBBlueLightClient class. Apple can rename, resign, or delete any of them
// in a future macOS release without notice, so every lookup here is
// optional and every caller in ActionRegistry treats a missing symbol or
// class as `.unavailable` rather than crashing. Community reports (see
// blueutil's README) say the Bluetooth power setter can silently do
// nothing on macOS 26, which is why the registry re-reads after writing it
// instead of trusting the setter's return value.

private func resolveSymbol<T>(_ path: String, _ symbol: String) -> T? {
    guard let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, symbol) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

struct BluetoothAPI {
    let getPower: @convention(c) () -> Int32
    let setPower: @convention(c) (Int32) -> Int32

    static func resolve() -> BluetoothAPI? {
        let path = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
        guard let getPower: (@convention(c) () -> Int32) =
                resolveSymbol(path, "IOBluetoothPreferenceGetControllerPowerState"),
              let setPower: (@convention(c) (Int32) -> Int32) =
                resolveSymbol(path, "IOBluetoothPreferenceSetControllerPowerState")
        else { return nil }
        return BluetoothAPI(getPower: getPower, setPower: setPower)
    }
}

struct BrightnessAPI {
    let get: @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    let set: @convention(c) (CGDirectDisplayID, Float) -> Int32

    static func resolve() -> BrightnessAPI? {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let get: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32) =
                resolveSymbol(path, "DisplayServicesGetBrightness"),
              let set: (@convention(c) (CGDirectDisplayID, Float) -> Int32) =
                resolveSymbol(path, "DisplayServicesSetBrightness")
        else { return nil }
        return BrightnessAPI(get: get, set: set)
    }
}

struct LockScreenAPI {
    let lock: @convention(c) () -> Int32

    static func resolve() -> LockScreenAPI? {
        let path = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let lock: (@convention(c) () -> Int32) = resolveSymbol(path, "SACLockScreenImmediate")
        else { return nil }
        return LockScreenAPI(lock: lock)
    }
}

/// Wraps CBBlueLightClient, which lives in a private framework and has no
/// public Swift or Objective-C interface, so its methods are called through
/// `objc_msgSend` and its status struct is read as raw bytes.
final class NightShiftAPI {
    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private let client: NSObject
    private let getStatus: GetStatus
    private let setEnabledFn: SetEnabled

    init?() {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(path, RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type,
              let getStatus: GetStatus = resolveSymbol("/usr/lib/libobjc.A.dylib", "objc_msgSend"),
              let setEnabled: SetEnabled = resolveSymbol("/usr/lib/libobjc.A.dylib", "objc_msgSend")
        else { return nil }
        client = cls.init()
        self.getStatus = getStatus
        self.setEnabledFn = setEnabled
    }

    func isEnabled() -> Bool? {
        var status = [UInt8](repeating: 0, count: 64)
        let ok = status.withUnsafeMutableBytes { buffer in
            getStatus(client, NSSelectorFromString("getBlueLightStatus:"), buffer.baseAddress!)
        }
        guard ok else { return nil }
        // CBBlueLightClient's status struct starts with `active` at offset 0
        // and `enabled` at offset 1 on this macOS version.
        return status[1] != 0
    }

    func setEnabled(_ on: Bool) -> Bool {
        setEnabledFn(client, NSSelectorFromString("setEnabled:"), on)
    }
}

/// True Tone, from the same private framework Night Shift uses.
///
/// `CBTrueToneClient` lives in the dyld shared cache, so the selectors cannot
/// be read off disk and are taken from the class's own interface: `-enabled`,
/// `-setEnabled:`, and `-supported` for the Macs whose display has no ambient
/// sensor. Anything missing means `init?` returns nil and the action reports
/// itself unavailable, which is the same guard Bluetooth and brightness use.
final class TrueToneAPI {
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private let client: NSObject
    private let get: BoolGetter
    private let set: BoolSetter

    init?() {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(path, RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBTrueToneClient") as? NSObject.Type,
              let get: BoolGetter = resolveSymbol("/usr/lib/libobjc.A.dylib", "objc_msgSend"),
              let set: BoolSetter = resolveSymbol("/usr/lib/libobjc.A.dylib", "objc_msgSend")
        else { return nil }
        let instance = cls.init()
        guard instance.responds(to: NSSelectorFromString("enabled")),
              instance.responds(to: NSSelectorFromString("setEnabled:")) else { return nil }
        // A Mac whose display has no ambient sensor answers false here, and
        // the action is better hidden than shown doing nothing.
        if instance.responds(to: NSSelectorFromString("supported")),
           !get(instance, NSSelectorFromString("supported")) { return nil }
        client = instance
        self.get = get
        self.set = set
    }

    func isEnabled() -> Bool { get(client, NSSelectorFromString("enabled")) }

    @discardableResult
    func setEnabled(_ on: Bool) -> Bool { set(client, NSSelectorFromString("setEnabled:"), on) }
}

enum PrivateAPI {
    static let trueTone: TrueToneAPI? = TrueToneAPI()
    static let bluetooth: BluetoothAPI? = BluetoothAPI.resolve()
    static let brightness: BrightnessAPI? = BrightnessAPI.resolve()
    static let lockScreen: LockScreenAPI? = LockScreenAPI.resolve()
    static let nightShift: NightShiftAPI? = NightShiftAPI()
}

/// Runs a private call off the cooperative pool with its own deadline.
///
/// A private symbol can block forever (IOBluetooth's coordinator has been
/// seen waiting on a semaphore that never signals). On the cooperative pool
/// that steals a thread Swift concurrency needs for the timeout itself, so
/// the call goes to a global GCD queue instead and the deadline is a plain
/// dispatch timer. A call that misses its deadline marks the action wedged;
/// the thread it holds is written off for the session and nothing asks
/// that action again.
enum PrivateCall {
    static var timeout: TimeInterval = 2

    private static let lock = NSLock()
    private static var wedgedIDs: Set<ActionID> = []

    static func isWedged(_ id: ActionID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wedgedIDs.contains(id)
    }

    static func resetWedged() {
        lock.lock(); defer { lock.unlock() }
        wedgedIDs.removeAll()
    }

    /// Nil when the action is wedged already or the call missed its deadline.
    static func run<T: Sendable>(_ id: ActionID, _ body: @escaping @Sendable () -> T) async -> T? {
        guard !isWedged(id) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = NSLock()
            var settled = false
            DispatchQueue.global(qos: .userInitiated).async {
                let value = body()
                gate.lock()
                let first = !settled
                settled = true
                gate.unlock()
                if first { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                gate.lock()
                let first = !settled
                settled = true
                gate.unlock()
                guard first else { return }
                lock.lock()
                wedgedIDs.insert(id)
                lock.unlock()
                Log.drawer.error("\(id.rawValue, privacy: .public) did not answer in \(timeout)s; unavailable for this session")
                continuation.resume(returning: nil)
            }
        }
    }
}
