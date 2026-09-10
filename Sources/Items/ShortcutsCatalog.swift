import Foundation

@MainActor
final class ShortcutsCatalog: ObservableObject {
    @Published private(set) var names: [String]?
    @Published private(set) var failed = false
    @Published private(set) var isLoading = false

    private let loader: () async throws -> ShellResult

    init(loader: @escaping () async throws -> ShellResult = {
        try await Shell.run("/usr/bin/shortcuts", ["list"])
    }) {
        self.loader = loader
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await loader()
            guard result.status == 0 else {
                failed = true
                return
            }
            names = Self.parse(result.stdout)
            failed = false
        } catch {
            failed = true
        }
    }

    static func parse(_ output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
