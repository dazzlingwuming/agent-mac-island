import Foundation
import OpenIslandCore

struct IdleSessionDismissalRecord: Codable, Equatable, Sendable {
    let sessionID: String
    let lastSeenUpdatedAt: TimeInterval
    let dismissedAt: TimeInterval

    init(session: AgentSession, dismissedAt: Date = .now) {
        sessionID = session.id
        lastSeenUpdatedAt = session.updatedAt.timeIntervalSince1970
        self.dismissedAt = dismissedAt.timeIntervalSince1970
    }

    func hides(_ session: AgentSession) -> Bool {
        guard session.id == sessionID else { return false }
        return session.updatedAt.timeIntervalSince1970 <= lastSeenUpdatedAt
    }
}

final class IdleSessionDismissalStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let records: [IdleSessionDismissalRecord]
    }

    static let currentVersion = 1

    static var defaultFileURL: URL {
        CodexSessionStore.defaultDirectoryURL
            .appendingPathComponent("dismissed-idle-sessions.json")
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = IdleSessionDismissalStore.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> [String: IdleSessionDismissalRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == Self.currentVersion else {
            return [:]
        }

        return Dictionary(
            document.records.map { ($0.sessionID, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    func save(_ recordsByID: [String: IdleSessionDismissalRecord]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let document = Document(
            version: Self.currentVersion,
            records: recordsByID.values.sorted { $0.sessionID < $1.sessionID }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }
}
