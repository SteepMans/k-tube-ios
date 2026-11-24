import Foundation
import Security
import SwiftUI

/// The tc_ key and the gateway address from the user's link live in the Keychain, never in files or settings.
enum Keychain {
    static let service = "ru.steepmans.ktube"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Library and settings on disk (Application Support, JSON), saved a moment after each change.
@MainActor
final class Store: ObservableObject {
    @Published var library: Library { didSet { scheduleSave(library: true) } }
    @Published var settings: AppSettings { didSet { scheduleSave(library: false) } }

    private var saveLibrary: Task<Void, Never>?
    private var saveSettings: Task<Void, Never>?
    private let dir: URL

    init(ephemeral: Bool = false) {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        dir = ephemeral ? FileManager.default.temporaryDirectory.appendingPathComponent("ktube-demo") : base
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        library = (try? JSONDecoder().decode(Library.self, from: Data(contentsOf: dir.appendingPathComponent("library.json")))) ?? Library()
        settings = (try? JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: dir.appendingPathComponent("settings.json")))) ?? AppSettings()
    }

    private func scheduleSave(library lib: Bool) {
        if lib {
            saveLibrary?.cancel()
            let snapshot = library
            let url = dir.appendingPathComponent("library.json")
            saveLibrary = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
            }
        } else {
            saveSettings?.cancel()
            let snapshot = settings
            let url = dir.appendingPathComponent("settings.json")
            saveSettings = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
            }
        }
    }

    /// Writes right away (the app is going to the background).
    func flush() {
        if let d = try? JSONEncoder().encode(library) { try? d.write(to: dir.appendingPathComponent("library.json"), options: .atomic) }
        if let d = try? JSONEncoder().encode(settings) { try? d.write(to: dir.appendingPathComponent("settings.json"), options: .atomic) }
    }

    var accent: Color { Color(hex: settings.accent) }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }
}
