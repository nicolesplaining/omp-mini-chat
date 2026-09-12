import Foundation
import Combine

final class ChatNames: ObservableObject {
    static let shared = ChatNames()
    private let defaults: UserDefaults
    private let key = "ompMini.chatNames"
    @Published private var names: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func title(for id: String, fallback: String) -> String { names[id] ?? fallback }

    func hasCustomName(_ id: String) -> Bool { names[id] != nil }

    func reset(_ id: String) {
        names.removeValue(forKey: id)
        defaults.set(names, forKey: key)
    }

    func rename(_ id: String, to title: String) {
        let cleaned = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !id.isEmpty, !cleaned.isEmpty else { return }
        names[id] = String(cleaned.prefix(120))
        defaults.set(names, forKey: key)
    }
}
