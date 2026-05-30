import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import Metal
import MetalKit
import Photos
import QuartzCore
import CryptoKit
import Darwin
import Security
import simd
import UniformTypeIdentifiers

enum FrameInterpolationStore {
    private static let key = "frameInterpolationEnabled"

    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

enum NaturalDenoiseStore {
    private static let key = "naturalDenoiseEnabled"
    private static let strengthKey = "naturalDenoiseStrength"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var strength: Float {
        get {
            guard UserDefaults.standard.object(forKey: strengthKey) != nil else { return 0.72 }
            return max(0, min(1, UserDefaults.standard.float(forKey: strengthKey)))
        }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: strengthKey)
        }
    }
}

enum ToneRecoveryStore {
    private static let enabledKey = "toneRecoveryEnabled"
    private static let strengthKey = "toneRecoveryStrength"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var strength: Float {
        get {
            guard UserDefaults.standard.object(forKey: strengthKey) != nil else { return 0.58 }
            return max(0, min(1, UserDefaults.standard.float(forKey: strengthKey)))
        }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: strengthKey)
        }
    }
}

enum BrightnessBoostStore {
    private static let strengthKey = "brightnessBoostStrength"

    static var strength: Float {
        get {
            guard UserDefaults.standard.object(forKey: strengthKey) != nil else { return 0 }
            return max(0, min(1, UserDefaults.standard.float(forKey: strengthKey)))
        }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: strengthKey)
        }
    }
}

enum MagicRescueStore {
    private static let enabledKey = "magicRescueEnabled"
    private static let strengthKey = "magicRescueStrength"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var strength: Float {
        get {
            guard UserDefaults.standard.object(forKey: strengthKey) != nil else { return 0.82 }
            return max(0, min(1, UserDefaults.standard.float(forKey: strengthKey)))
        }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: strengthKey)
        }
    }
}

enum SplitCompareStore {
    private static let key = "splitCompareEnabled"
    private static let reversedKey = "splitCompareReversed"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var reversed: Bool {
        get { UserDefaults.standard.bool(forKey: reversedKey) }
        set { UserDefaults.standard.set(newValue, forKey: reversedKey) }
    }
}

enum DebugInformationStore {
    private static let key = "debugInformationEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum DefaultQualityStore {
    private static let qualityModeKey = "defaultMetalQualityModeRaw"

    static var qualityModeRaw: Int {
        get {
            guard UserDefaults.standard.object(forKey: qualityModeKey) != nil else { return 0 }
            return UserDefaults.standard.integer(forKey: qualityModeKey)
        }
        set {
            UserDefaults.standard.set(max(0, min(4, newValue)), forKey: qualityModeKey)
        }
    }
}

enum ProcessCPUUsage {
    static func currentPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else { return 0 }
        defer {
            let byteCount = vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), byteCount)
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if status == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return max(0, total)
    }
}
