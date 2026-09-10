import Foundation

enum DrawerItem: Codable, Hashable, Identifiable {
    case app(bundleID: String)
    case action(String)
    case shortcut(name: String)

    private enum Tag: String, Codable {
        case app, action, shortcut
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    var id: String {
        switch self {
        case .app(let bundleID): return "app:\(bundleID)"
        case .action(let raw): return "action:\(raw)"
        case .shortcut(let name): return "shortcut:\(name)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(Tag.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch tag {
        case .app: self = .app(bundleID: value)
        case .action: self = .action(value)
        case .shortcut: self = .shortcut(name: value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let bundleID):
            try container.encode(Tag.app, forKey: .kind)
            try container.encode(bundleID, forKey: .value)
        case .action(let raw):
            try container.encode(Tag.action, forKey: .kind)
            try container.encode(raw, forKey: .value)
        case .shortcut(let name):
            try container.encode(Tag.shortcut, forKey: .kind)
            try container.encode(name, forKey: .value)
        }
    }

    /// A wrapper whose own decode never throws: a bad element becomes `nil`
    /// instead of failing the whole array, which is what lets `decodeList`
    /// keep every element around it.
    private struct Element: Decodable {
        let item: DrawerItem?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            item = try? container.decode(DrawerItem.self)
        }
    }

    static func decodeList(_ data: Data) -> [DrawerItem] {
        guard let elements = try? JSONDecoder().decode([Element].self, from: data) else {
            Log.drawer.error("items blob did not decode at all, treating it as empty")
            return []
        }
        var seenIDs = Set<String>()
        var items: [DrawerItem] = []
        for element in elements {
            guard let item = element.item else {
                Log.drawer.error("dropped a malformed item while decoding")
                continue
            }
            guard seenIDs.insert(item.id).inserted else { continue }
            items.append(item)
        }
        return items
    }

    static func encodeList(_ items: [DrawerItem]) -> Data {
        (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
    }
}
