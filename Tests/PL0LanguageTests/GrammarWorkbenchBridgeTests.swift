import Foundation
import Testing
@testable import PL0Language

@Suite("Grammar Workbench hot reload bridge")
struct GrammarWorkbenchBridgeTests {
    @Test func connectsAndOpensRetainedDocument() async throws {
        let transport = MockWorkbenchTransport()
        let bridge = GrammarWorkbenchHotReloadSession(transport: transport)
        let status = try await bridge.connect(
            grammar: validGrammar, document: "begin end.", revision: 7)
        #expect(status.state == .connected)
        #expect(status.documentRevision == 7)
        #expect(status.parseStatus == "accepted")
        #expect(await transport.operations() == ["capabilities", "sessionOpen", "documentOpen"])
    }

    @Test func documentUpdateUsesUTF16FullRangeAndRevision() async throws {
        let transport = MockWorkbenchTransport()
        let bridge = GrammarWorkbenchHotReloadSession(transport: transport)
        _ = try await bridge.connect(grammar: validGrammar,
                                     document: "// 😀\r\nbegin end.", revision: 1)
        let status = try await bridge.updateDocument("begin call p end.", revision: 2)
        #expect(status.documentRevision == 2)
        let edit = await transport.lastEdit()
        #expect(edit?.endLine == 1)
        #expect(edit?.endColumn == 10)
        #expect(edit?.replacement == "begin call p end.")
    }

    @Test func validReloadActivatesNextGrammarRevision() async throws {
        let transport = MockWorkbenchTransport()
        let bridge = GrammarWorkbenchHotReloadSession(transport: transport)
        _ = try await bridge.connect(grammar: validGrammar,
                                     document: "begin end.", revision: 1)
        let status = try await bridge.reload(grammar: validGrammar + "\nUnused : ;")
        #expect(status.grammarRevision == 1)
        #expect(status.reloadCount == 1)
        #expect(status.message == "Grammar hot-reloaded")
    }

    @Test func invalidReloadPreservesActiveRevisionAndDocumentSummary() async throws {
        let transport = MockWorkbenchTransport()
        let bridge = GrammarWorkbenchHotReloadSession(transport: transport)
        let original = try await bridge.connect(grammar: validGrammar,
                                                document: "begin end.", revision: 4)
        await #expect(throws: GrammarWorkbenchBridgeError.self) {
            try await bridge.reload(grammar: "INVALID")
        }
        let status = await bridge.status()
        #expect(status.state == .connected)
        #expect(status.grammarRevision == original.grammarRevision)
        #expect(status.documentRevision == 4)
        #expect(status.reloadCount == 0)
        #expect(status.message.contains("Reload rejected"))
    }

    @Test func disconnectClosesServiceSession() async throws {
        let transport = MockWorkbenchTransport()
        let bridge = GrammarWorkbenchHotReloadSession(transport: transport)
        _ = try await bridge.connect(grammar: validGrammar,
                                     document: ".", revision: 1)
        await bridge.disconnect()
        #expect(await bridge.status().state == .disconnected)
        #expect(await transport.operations().last == "sessionClose")
    }

    @Test func realJSONLinesServiceAcceptsBundledPL0GrammarWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let servicePath = environment["MODEDIT_TEST_GRAMMAR_WORKBENCH_SERVICE"],
              let grammarPath = environment["MODEDIT_TEST_PL0_GRAMMAR"] else { return }
        let transport = try GrammarWorkbenchProcessTransport(
            executableURL: URL(fileURLWithPath: servicePath))
        let bridge = GrammarWorkbenchHotReloadSession(
            transport: transport, sessionID: "modedit-integration-\(UUID().uuidString)")
        let grammar = try String(contentsOfFile: grammarPath, encoding: .utf8)
        let status = try await bridge.connect(
            grammar: grammar,
            document: "var x; begin x := 1; while x < 3 do x := x + 1 end.",
            revision: 1)
        #expect(status.state == .connected)
        #expect(status.parseStatus == "accepted")
        await bridge.disconnect()
        await transport.stop()
    }

    private var validGrammar: String {
        "%start Program\n%token PERIOD /\\./\n%skip /\\s+/\nProgram : PERIOD ;"
    }
}

private actor MockWorkbenchTransport: GrammarWorkbenchTransport {
    private var requests: [[String: Any]] = []
    private var grammarRevision = 0
    private var documentRevision = 0

    func send(_ request: Data) async throws -> Data {
        let value = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        requests.append(value)
        let operation = value["operation"] as? String ?? ""
        let requestID = value["requestID"] as? String ?? ""
        if operation == "sessionReplaceGrammar",
           let compilation = value["compilation"] as? [String: Any],
           (compilation["source"] as? String)?.contains("INVALID") == true {
            return response(requestID: requestID, status: "failure",
                            error: ["code": "compilation-failed",
                                    "message": "Replacement grammar did not compile"])
        }
        if operation == "sessionReplaceGrammar" { grammarRevision += 1 }
        if let revision = value["revision"] as? Int { documentRevision = revision }
        return response(requestID: requestID, status: "success")
    }

    func operations() -> [String] { requests.compactMap { $0["operation"] as? String } }
    func lastEdit() -> MockEditSummary? {
        guard let edit = (requests.last?["edits"] as? [[String: Any]])?.first,
              let range = edit["range"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let line = end["line"] as? Int,
              let column = end["utf16Column"] as? Int,
              let replacement = edit["replacement"] as? String else { return nil }
        return MockEditSummary(endLine: line, endColumn: column,
                               replacement: replacement)
    }

    private func response(requestID: String, status: String,
                          error: [String: String]? = nil) -> Data {
        var value: [String: Any] = [
            "schemaVersion": 1, "requestID": requestID, "apiVersion": 1,
            "status": status,
            "session": [
                "grammarRevision": grammarRevision,
                "documents": [[
                    "id": "main.pl0", "revision": documentRevision,
                    "parseStatus": "accepted", "lexicalDiagnosticCount": 0,
                    "syntaxDiagnosticCount": 0, "tokenCount": 3
                ]]
            ]
        ]
        if let error { value["error"] = error }
        if documentRevision > 0 {
            value["document"] = [
                "text": ["revision": documentRevision],
                "lexing": ["tokens": [[:], [:], [:]], "diagnostics": []],
                "parse": ["status": "accepted", "diagnostics": []]
            ]
        }
        return try! JSONSerialization.data(withJSONObject: value)
    }
}

private struct MockEditSummary: Sendable {
    let endLine: Int
    let endColumn: Int
    let replacement: String
}
