import Foundation

enum DrawerEdit: Equatable {
    case add(DrawerItem, before: String?)
    case move(id: String, before: String?)
    case remove(id: String)

    var itemID: String {
        switch self {
        case .add(let item, _): return item.id
        case .move(let id, _), .remove(let id): return id
        }
    }

    var actionName: String {
        switch self {
        case .add: return "Add item"
        case .move: return "Move item"
        case .remove: return "Remove item"
        }
    }

    func applying(to items: [DrawerItem]) -> [DrawerItem]? {
        var result = items
        switch self {
        case .add(let item, let neighbor):
            guard !items.contains(where: { $0.id == item.id }) else { return nil }
            if let neighbor {
                guard let index = result.firstIndex(where: { $0.id == neighbor }) else { return nil }
                result.insert(item, at: index)
            } else {
                result.append(item)
            }
        case .move(let id, let neighbor):
            guard id != neighbor,
                  let source = result.firstIndex(where: { $0.id == id }) else { return nil }
            let item = result.remove(at: source)
            if let neighbor {
                guard let index = result.firstIndex(where: { $0.id == neighbor }) else { return nil }
                result.insert(item, at: index)
            } else {
                result.append(item)
            }
        case .remove(let id):
            guard let source = result.firstIndex(where: { $0.id == id }) else { return nil }
            result.remove(at: source)
        }
        return result == items ? nil : result
    }
}

struct DrawerItemPosition {
    let id: String
    let item: DrawerItem?
    let previousID: String?
    let nextID: String?

    init(id: String, in items: [DrawerItem]) {
        self.id = id
        if let index = items.firstIndex(where: { $0.id == id }) {
            item = items[index]
            previousID = index > 0 ? items[index - 1].id : nil
            nextID = index + 1 < items.count ? items[index + 1].id : nil
        } else {
            item = nil
            previousID = nil
            nextID = nil
        }
    }

    func restoring(in items: [DrawerItem]) -> [DrawerItem] {
        var result = items.filter { $0.id != id }
        guard let item else { return result }
        if let nextID, let next = result.firstIndex(where: { $0.id == nextID }) {
            result.insert(item, at: next)
        } else if let previousID, let previous = result.firstIndex(where: { $0.id == previousID }) {
            result.insert(item, at: previous + 1)
        } else if previousID == nil {
            result.insert(item, at: 0)
        } else {
            result.append(item)
        }
        return result
    }
}
