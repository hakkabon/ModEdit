import Foundation

public protocol GrammarWorkbenchTransport: Sendable {
    func send(_ request: Data) async throws -> Data
    func close() async
}

public extension GrammarWorkbenchTransport {
    func close() async {}
}

public enum GrammarWorkbenchBridgeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidResponse
    case service(code: String, message: String)
    case notConnected
    case processLaunch(String)
    case processEnded(String)

    public var description: String {
        switch self {
        case .invalidResponse: "Grammar Workbench returned an invalid response"
        case let .service(code, message): "Grammar Workbench \(code): \(message)"
        case .notConnected: "Grammar Workbench session is not connected"
        case let .processLaunch(message): "Could not launch Grammar Workbench: \(message)"
        case let .processEnded(message): "Grammar Workbench service ended: \(message)"
        }
    }
}

public enum GrammarWorkbenchConnectionState: String, Sendable, Equatable {
    case disconnected, connecting, connected, failed
}

public struct GrammarWorkbenchHotReloadStatus: Sendable, Equatable {
    public let state: GrammarWorkbenchConnectionState
    public let grammarRevision: Int
    public let documentRevision: UInt64?
    public let parseStatus: String?
    public let tokenCount: Int
    public let lexicalDiagnosticCount: Int
    public let syntaxDiagnosticCount: Int
    public let reloadCount: Int
    public let message: String

    public init(state: GrammarWorkbenchConnectionState,
                grammarRevision: Int = 0, documentRevision: UInt64? = nil,
                parseStatus: String? = nil, tokenCount: Int = 0,
                lexicalDiagnosticCount: Int = 0,
                syntaxDiagnosticCount: Int = 0, reloadCount: Int = 0,
                message: String = "Not connected") {
        self.state = state
        self.grammarRevision = grammarRevision
        self.documentRevision = documentRevision
        self.parseStatus = parseStatus
        self.tokenCount = tokenCount
        self.lexicalDiagnosticCount = lexicalDiagnosticCount
        self.syntaxDiagnosticCount = syntaxDiagnosticCount
        self.reloadCount = reloadCount
        self.message = message
    }

    public static let disconnected = GrammarWorkbenchHotReloadStatus(state: .disconnected)
}

/// Stateful client for Grammar Workbench's schema-1 JSON-lines service. A
/// grammar replacement is activated only after Workbench compiles it and
/// reanalyzes the retained document successfully at the protocol level.
public actor GrammarWorkbenchHotReloadSession {
    private let transport: any GrammarWorkbenchTransport
    private let sessionID: String
    private let documentID: String
    private var sourceText = ""
    private var statusValue = GrammarWorkbenchHotReloadStatus.disconnected

    public init(transport: any GrammarWorkbenchTransport,
                sessionID: String = "modedit-pl0",
                documentID: String = "main.pl0") {
        self.transport = transport
        self.sessionID = sessionID
        self.documentID = documentID
    }

    public func status() -> GrammarWorkbenchHotReloadStatus { statusValue }

    @discardableResult
    public func connect(grammar: String, document: String,
                        revision: UInt64) async throws -> GrammarWorkbenchHotReloadStatus {
        statusValue = GrammarWorkbenchHotReloadStatus(
            state: .connecting, message: "Connecting to Grammar Workbench…")
        do {
            _ = try await request(operation: "capabilities")
            _ = try await request(operation: "sessionOpen", grammar: grammar)
            let opened = try await request(operation: "documentOpen", input: document,
                                           revision: revision)
            sourceText = document
            statusValue = makeStatus(opened, state: .connected,
                                     message: "Grammar Workbench connected")
            return statusValue
        } catch {
            statusValue = GrammarWorkbenchHotReloadStatus(
                state: .failed, message: String(describing: error))
            throw error
        }
    }

    /// Sends one full-range UTF-16 edit. Grammar Workbench retains its own
    /// incremental lexer/parser state and decides the reusable suffix.
    @discardableResult
    public func updateDocument(_ text: String,
                               revision: UInt64) async throws -> GrammarWorkbenchHotReloadStatus {
        guard statusValue.state == .connected else { throw GrammarWorkbenchBridgeError.notConnected }
        guard text != sourceText || statusValue.documentRevision != revision else { return statusValue }
        let end = Self.endPosition(sourceText)
        let response = try await request(
            operation: "documentChange", revision: revision,
            edits: [WireEdit(range: WireRange(start: .init(line: 0, utf16Column: 0),
                                                end: end), replacement: text)])
        sourceText = text
        statusValue = makeStatus(response, state: .connected,
                                 message: "Document analyzed")
        return statusValue
    }

    /// Invalid replacements leave the active Workbench grammar and revision
    /// untouched; only the status message changes.
    @discardableResult
    public func reload(grammar: String) async throws -> GrammarWorkbenchHotReloadStatus {
        guard statusValue.state == .connected else { throw GrammarWorkbenchBridgeError.notConnected }
        let previous = statusValue
        do {
            let response = try await request(operation: "sessionReplaceGrammar",
                                             grammar: grammar)
            statusValue = makeStatus(
                response, state: .connected,
                reloadCount: previous.reloadCount + 1,
                message: "Grammar hot-reloaded")
            return statusValue
        } catch {
            statusValue = GrammarWorkbenchHotReloadStatus(
                state: .connected, grammarRevision: previous.grammarRevision,
                documentRevision: previous.documentRevision,
                parseStatus: previous.parseStatus, tokenCount: previous.tokenCount,
                lexicalDiagnosticCount: previous.lexicalDiagnosticCount,
                syntaxDiagnosticCount: previous.syntaxDiagnosticCount,
                reloadCount: previous.reloadCount,
                message: "Reload rejected: \(error)")
            throw error
        }
    }

    public func disconnect() async {
        if statusValue.state == .connected {
            _ = try? await request(operation: "sessionClose")
        }
        sourceText = ""
        statusValue = .disconnected
        await transport.close()
    }

    private func request(operation: String, grammar: String? = nil,
                         input: String? = nil, revision: UInt64? = nil,
                         edits: [WireEdit]? = nil) async throws -> WireResponse {
        let request = WireRequest(
            schemaVersion: 1, requestID: UUID().uuidString, apiVersion: 1,
            operation: operation,
            compilation: grammar.map { WireCompilation(source: $0,
                                                        algorithm: "LALR(1)",
                                                        notation: "Workbench") },
            input: input,
            sessionID: operation == "capabilities" ? nil : sessionID,
            documentID: ["documentOpen", "documentChange"].contains(operation)
                ? documentID : nil,
            revision: revision.flatMap { Int(exactly: $0) }, edits: edits)
        let encoded = try JSONEncoder().encode(request)
        let response = try JSONDecoder().decode(WireResponse.self,
                                                from: await transport.send(encoded))
        guard response.requestID == request.requestID else {
            throw GrammarWorkbenchBridgeError.invalidResponse
        }
        if response.status != "success" {
            throw GrammarWorkbenchBridgeError.service(
                code: response.error?.code ?? "failure",
                message: response.error?.message ?? "Unknown service failure")
        }
        return response
    }

    private func makeStatus(_ response: WireResponse,
                            state: GrammarWorkbenchConnectionState,
                            reloadCount: Int? = nil,
                            message: String) -> GrammarWorkbenchHotReloadStatus {
        let document = response.document
        let summary = response.session?.documents.first { $0.id == documentID }
        return GrammarWorkbenchHotReloadStatus(
            state: state,
            grammarRevision: response.session?.grammarRevision ?? statusValue.grammarRevision,
            documentRevision: (document?.text.revision).flatMap { UInt64(exactly: $0) }
                ?? (summary?.revision).flatMap { UInt64(exactly: $0) }
                ?? statusValue.documentRevision,
            parseStatus: document?.parse.status ?? summary?.parseStatus
                ?? statusValue.parseStatus,
            tokenCount: document?.lexing.tokens.count ?? summary?.tokenCount
                ?? statusValue.tokenCount,
            lexicalDiagnosticCount: document?.lexing.diagnostics.count
                ?? summary?.lexicalDiagnosticCount ?? statusValue.lexicalDiagnosticCount,
            syntaxDiagnosticCount: document?.parse.diagnostics.count
                ?? summary?.syntaxDiagnosticCount ?? statusValue.syntaxDiagnosticCount,
            reloadCount: reloadCount ?? statusValue.reloadCount,
            message: message)
    }

    private static func endPosition(_ text: String) -> WirePosition {
        let units = Array(text.utf16)
        var line = 0
        var column = 0
        var index = 0
        while index < units.count {
            if units[index] == 13 {
                line += 1; column = 0; index += 1
                if index < units.count, units[index] == 10 { index += 1 }
            } else if units[index] == 10 {
                line += 1; column = 0; index += 1
            } else {
                column += 1; index += 1
            }
        }
        return WirePosition(line: line, utf16Column: column)
    }
}

/// A sequential JSON-lines process transport. Serialization is intentional:
/// the service supports out-of-order replies, but one in-flight request keeps
/// this small editor adapter deterministic and avoids a response router.
public actor GrammarWorkbenchProcessTransport: GrammarWorkbenchTransport {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private var readBuffer = Data()

    public init(executableURL: URL) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do { try process.run() }
        catch { throw GrammarWorkbenchBridgeError.processLaunch(error.localizedDescription) }
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
    }

    public func send(_ request: Data) async throws -> Data {
        guard process.isRunning else { throw ended() }
        var line = request
        line.append(0x0A)
        do { try input.write(contentsOf: line) }
        catch { throw GrammarWorkbenchBridgeError.processEnded(error.localizedDescription) }
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let response = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                return Data(response)
            }
            let chunk = await nextAvailableChunk()
            guard !chunk.isEmpty else {
                throw ended()
            }
            readBuffer.append(chunk)
        }
    }

    public func stop() {
        try? input.close()
        if process.isRunning { process.terminate() }
    }

    public func close() async { stop() }

    private func ended() -> GrammarWorkbenchBridgeError {
        let data = errorOutput.availableData
        return .processEnded(String(data: data, encoding: .utf8) ?? "service exited")
    }

    private func nextAvailableChunk() async -> Data {
        await withCheckedContinuation { continuation in
            output.readabilityHandler = { handle in
                handle.readabilityHandler = nil
                continuation.resume(returning: handle.availableData)
            }
        }
    }
}

private struct WireRequest: Encodable {
    let schemaVersion: Int
    let requestID: String
    let apiVersion: Int
    let operation: String
    let compilation: WireCompilation?
    let input: String?
    let sessionID: String?
    let documentID: String?
    let revision: Int?
    let edits: [WireEdit]?
}

private struct WireCompilation: Encodable {
    let source: String
    let algorithm: String
    let notation: String
}

private struct WireEdit: Codable {
    let range: WireRange
    let replacement: String
}

private struct WireRange: Codable {
    let start: WirePosition
    let end: WirePosition
}

private struct WirePosition: Codable {
    let line: Int
    let utf16Column: Int
}

private struct WireResponse: Decodable {
    let requestID: String
    let status: String
    let error: WireError?
    let session: WireSession?
    let document: WireDocument?
}

private struct WireError: Decodable { let code: String; let message: String }
private struct WireSession: Decodable {
    let grammarRevision: Int
    let documents: [WireDocumentSummary]
}
private struct WireDocumentSummary: Decodable {
    let id: String
    let revision: Int?
    let parseStatus: String?
    let lexicalDiagnosticCount: Int?
    let syntaxDiagnosticCount: Int?
    let tokenCount: Int?
}
private struct WireDocument: Decodable {
    let text: WireText
    let lexing: WireLexing
    let parse: WireParse
}
private struct WireText: Decodable { let revision: Int }
private struct WireLexing: Decodable {
    let tokens: [WireIgnored]
    let diagnostics: [WireIgnored]
}
private struct WireParse: Decodable {
    let status: String
    let diagnostics: [WireIgnored]
}
private struct WireIgnored: Decodable {}
