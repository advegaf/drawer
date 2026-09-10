enum Fixtures {
    static func cells(_ n: Int = 3) -> [DrawerCell] {
        let symbols = ["wifi", "moon.fill", "speaker.wave.2.fill", "bolt.fill", "lock.fill"]
        let templates: [(Kind, CellState)] = [
            (.toggle, .on),
            (.toggle, .off),
            (.level, .level(0.62)),
            (.fire(destructive: false), .ready),
            (.fire(destructive: false), .ready),
        ]
        return (0..<n).map { i in
            let symbol = symbols[i % symbols.count]
            let (kind, state) = templates[i % templates.count]
            return DrawerCell(id: "fixture-\(i)", title: symbol, icon: .symbol(symbol),
                              kind: kind, state: state)
        }
    }

    /// What a drawer looks like when somebody has actually set it up: eight
    /// cells that all work, no failed or unavailable state anywhere. This is
    /// the fixture the README images use, because `vocabulary()` below is a
    /// catalogue of every state including the broken ones, and a catalogue
    /// photographs as a bug report.
    static func curated() -> [DrawerCell] {
        [
            DrawerCell(id: "curated-wifi", title: "Wi-Fi", icon: .symbol("wifi"),
                       kind: .toggle, state: .on),
            DrawerCell(id: "curated-bluetooth", title: "Bluetooth", icon: .symbol("dot.radiowaves.left.and.right"),
                       kind: .toggle, state: .on),
            DrawerCell(id: "curated-volume", title: "Volume", icon: .symbol("speaker.wave.2.fill"),
                       kind: .level, state: .level(0.62)),
            DrawerCell(id: "curated-darkmode", title: "Dark mode", icon: .symbol("circle.lefthalf.filled"),
                       kind: .toggle, state: .off),
            DrawerCell(id: "curated-screenshot", title: "Screenshot", icon: .symbol("camera.viewfinder"),
                       kind: .fire(destructive: false), state: .ready),
            DrawerCell(id: "curated-lock", title: "Lock Screen", icon: .symbol("lock.fill"),
                       kind: .fire(destructive: false), state: .ready),
            DrawerCell(id: "curated-shortcut", title: "Start focus", icon: .symbol("square.2.layers.3d.fill"),
                       kind: .shortcut, state: .ready),
            DrawerCell.add,
        ]
    }

    /// One cell per state the column can show, for a look at the whole
    /// vocabulary at once rather than whatever a live Mac happens to be in.
    static func vocabulary() -> [DrawerCell] {
        [
            DrawerCell(id: "vocab-launch-ready", title: "Finder", icon: .symbol("macwindow"),
                      kind: .launch, state: .ready),
            DrawerCell(id: "vocab-launch-notinstalled", title: "Not installed", icon: .symbol("app.dashed"),
                      kind: .launch, state: .notInstalled),
            DrawerCell(id: "vocab-toggle-on", title: "Wi-Fi", icon: .symbol("wifi"),
                      kind: .toggle, state: .on),
            DrawerCell(id: "vocab-toggle-off", title: "Bluetooth", icon: .symbol("dot.radiowaves.left.and.right"),
                      kind: .toggle, state: .off),
            DrawerCell(id: "vocab-level", title: "Volume", icon: .symbol("speaker.wave.2.fill"),
                      kind: .level, state: .level(0.62)),
            DrawerCell(id: "vocab-pending", title: "Dark mode", icon: .symbol("circle.lefthalf.filled"),
                      kind: .toggle, state: .pending),
            DrawerCell(id: "vocab-armed", title: "Empty Trash", icon: .symbol("trash.fill"),
                      kind: .fire(destructive: true), state: .armed),
            DrawerCell(id: "vocab-failed", title: "Screenshot", icon: .symbol("camera.viewfinder"),
                      kind: .fire(destructive: false), state: .failed("Failed")),
            DrawerCell(id: "vocab-unavailable", title: "Night Shift", icon: .symbol("moon.haze.fill"),
                      kind: .toggle, state: .unavailable),
            DrawerCell(id: "vocab-notfound", title: "Focus Mode", icon: .symbol("square.2.layers.3d.fill"),
                      kind: .shortcut, state: .notFound),
            DrawerCell.add,
        ]
    }
}
