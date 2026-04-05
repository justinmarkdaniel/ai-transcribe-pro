import Foundation
import Combine

struct TranscriptionEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    let date: Date
    let text: String
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [TranscriptionEntry] = []

    private let defaultsKey = "transcription.history.v1"
    private let maxEntries = 200

    init() {
        load()
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = TranscriptionEntry(date: Date(), text: trimmed)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func delete(_ entry: TranscriptionEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data)
        else { return }
        entries = decoded
    }
}
