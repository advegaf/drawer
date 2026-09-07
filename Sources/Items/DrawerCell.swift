import AppKit

enum CellState: Equatable {
    case unknown
    case ready
    case on
    case off
    case level(Double)
    case pending
    case armed
    case notInstalled
    case unavailable
    case notFound
    case failed(String)

    var label: String {
        switch self {
        case .unknown, .ready, .pending:
            return ""
        case .on:
            return "On"
        case .off:
            return "Off"
        case .level(let value):
            guard value.isFinite else { return "Unavailable" }
            return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
        case .armed:
            return "Click again to confirm"
        case .notInstalled:
            return "Not installed"
        case .unavailable:
            return "Unavailable"
        case .notFound:
            return "Not found"
        case .failed(let message):
            return message
        }
    }
}

enum Icon {
    case image(NSImage)
    case symbol(String)
}

enum Kind: Equatable {
    case launch
    case toggle
    case level
    case fire(destructive: Bool)
    case shortcut
    case add
}

struct DrawerCell: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: Icon
    let kind: Kind
    var state: CellState

    static func == (lhs: DrawerCell, rhs: DrawerCell) -> Bool {
        lhs.id == rhs.id && lhs.state == rhs.state
    }

    /// Shown in place of an empty list: nothing pinned yet, and a way to fix that.
    static let add = DrawerCell(id: "add", title: "Add items", icon: .symbol("plus"), kind: .add, state: .ready)
}
