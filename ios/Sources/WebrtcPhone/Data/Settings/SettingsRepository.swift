import Foundation
import Combine

enum ThemeMode: String, Codable, CaseIterable { case system, light, dark }

enum QualityPreset: String, Codable, CaseIterable, Identifiable {
    case smooth, standard, high, ultra, original, custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .smooth: return "流畅"
        case .standard: return "标清"
        case .high: return "高清"
        case .ultra: return "超清"
        case .original: return "原画"
        case .custom: return "自定义"
        }
    }
    var maxSize: Int {
        switch self {
        case .smooth: return 720
        case .standard: return 1080
        case .high: return 1280
        case .ultra: return 1920
        case .original, .custom: return 0
        }
    }
    var maxFps: Int {
        switch self {
        case .smooth, .standard: return 30
        case .high, .ultra, .original, .custom: return 60
        }
    }
    var bitrateMbps: Int {
        switch self {
        case .smooth: return 2
        case .standard: return 4
        case .high: return 6
        case .ultra: return 10
        case .original: return 16
        case .custom: return 0
        }
    }
}

struct StreamSettings: Codable, Equatable {
    var preset: QualityPreset = .standard
    var maxSize: Int = QualityPreset.standard.maxSize
    var maxFps: Int = QualityPreset.standard.maxFps
    var bitrateMbps: Int = QualityPreset.standard.bitrateMbps
    var bwe = true
    var minBitrateMbps = 1
    var maxBitrateMbps = 20
    var audio = true
    var powerOff = false

    func withPreset(_ p: QualityPreset) -> StreamSettings {
        var s = self
        s.preset = p
        if p != .custom {
            s.maxSize = p.maxSize
            s.maxFps = p.maxFps
            s.bitrateMbps = p.bitrateMbps
        }
        return s
    }

    mutating func sanitize() {
        minBitrateMbps = min(max(minBitrateMbps, 1), 50)
        maxBitrateMbps = min(max(maxBitrateMbps, minBitrateMbps), 100)
        maxSize = min(max(maxSize, 0), 4096)
        maxFps = min(max(maxFps, 0), 144)
        bitrateMbps = min(max(bitrateMbps, 1), 100)
    }
}

struct AppSettings: Codable, Equatable {
    var themeMode: ThemeMode = .system
    var gridColumns = 2
    var haptics = true
    var keepScreenOn = true
    var clipboardSync = true
    var showNavBar = true
    var showStats = false
    var autoReconnect = true
    var orientationLock = "auto"
}

/// 本地设置仓库。键名对齐 Android 端 SettingsRepository.kt（s_* / a_*）。
final class SettingsRepository: ObservableObject {
    @Published var stream: StreamSettings
    @Published var app: AppSettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults.standard) {
        self.defaults = defaults
        var s = StreamSettings()
        s.preset = QualityPreset(rawValue: defaults.string(forKey: "s_preset") ?? "") ?? s.preset
        s.maxSize = defaults.object(forKey: "s_max_size") as? Int ?? s.maxSize
        s.maxFps = defaults.object(forKey: "s_max_fps") as? Int ?? s.maxFps
        s.bitrateMbps = defaults.object(forKey: "s_bitrate") as? Int ?? s.bitrateMbps
        s.bwe = defaults.object(forKey: "s_bwe") as? Bool ?? s.bwe
        s.minBitrateMbps = defaults.object(forKey: "s_min_bitrate") as? Int ?? s.minBitrateMbps
        s.maxBitrateMbps = defaults.object(forKey: "s_max_bitrate") as? Int ?? s.maxBitrateMbps
        s.audio = defaults.object(forKey: "s_audio") as? Bool ?? s.audio
        s.powerOff = defaults.object(forKey: "s_power_off") as? Bool ?? s.powerOff
        self.stream = s

        var a = AppSettings()
        a.themeMode = ThemeMode(rawValue: defaults.string(forKey: "a_theme") ?? "") ?? a.themeMode
        a.gridColumns = min(max(defaults.object(forKey: "a_grid") as? Int ?? a.gridColumns, 1), 4)
        a.haptics = defaults.object(forKey: "a_haptics") as? Bool ?? a.haptics
        a.keepScreenOn = defaults.object(forKey: "a_keep_on") as? Bool ?? a.keepScreenOn
        a.clipboardSync = defaults.object(forKey: "a_clipboard") as? Bool ?? a.clipboardSync
        a.showNavBar = defaults.object(forKey: "a_navbar") as? Bool ?? a.showNavBar
        a.showStats = defaults.object(forKey: "a_stats") as? Bool ?? a.showStats
        a.autoReconnect = defaults.object(forKey: "a_reconnect") as? Bool ?? a.autoReconnect
        a.orientationLock = defaults.string(forKey: "a_orientation") ?? a.orientationLock
        self.app = a
    }

    func updateStream(_ transform: (inout StreamSettings) -> Void) {
        var s = stream
        transform(&s)
        s.sanitize()
        stream = s
        defaults.set(s.preset.rawValue, forKey: "s_preset")
        defaults.set(s.maxSize, forKey: "s_max_size")
        defaults.set(s.maxFps, forKey: "s_max_fps")
        defaults.set(s.bitrateMbps, forKey: "s_bitrate")
        defaults.set(s.bwe, forKey: "s_bwe")
        defaults.set(s.minBitrateMbps, forKey: "s_min_bitrate")
        defaults.set(s.maxBitrateMbps, forKey: "s_max_bitrate")
        defaults.set(s.audio, forKey: "s_audio")
        defaults.set(s.powerOff, forKey: "s_power_off")
    }

    func resetStream() { updateStream { $0 = StreamSettings() } }

    func updateApp(_ transform: (inout AppSettings) -> Void) {
        var a = app
        transform(&a)
        a.gridColumns = min(max(a.gridColumns, 1), 4)
        app = a
        defaults.set(a.themeMode.rawValue, forKey: "a_theme")
        defaults.set(a.gridColumns, forKey: "a_grid")
        defaults.set(a.haptics, forKey: "a_haptics")
        defaults.set(a.keepScreenOn, forKey: "a_keep_on")
        defaults.set(a.clipboardSync, forKey: "a_clipboard")
        defaults.set(a.showNavBar, forKey: "a_navbar")
        defaults.set(a.showStats, forKey: "a_stats")
        defaults.set(a.autoReconnect, forKey: "a_reconnect")
        defaults.set(a.orientationLock, forKey: "a_orientation")
    }
}
