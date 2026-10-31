import Foundation
import LanguageExperimentProtocol

/// PL/0 projection into the shared, language-neutral experiment schema.
/// Keeping this adapter outside the schema target prevents PL/0 token and tree
/// types from leaking into Grammar-REPL, Grammar-Workbench, or other clients.
public enum PL0ExperimentContract {
    public static func grammarArtifact(
        source: String,
        revision: UInt64 = 1,
        artifactID: String = "org.hakkabon.modedit.pl0",
        notation: String = "Workbench",
        normalForm: String? = "BNF"
    ) throws -> GrammarArtifactIdentity {
        try .sourceArtifact(id: artifactID, languageID: "pl0",
                            revision: revision, notation: notation,
                            source: source, normalForm: normalForm)
    }

    public static func bundle(
        id: String,
        title: String,
        runs: [ParseExperimentRun],
        metadata: [String: String] = [:]
    ) throws -> LanguageExperimentBundle {
        try LanguageExperimentBundle(id: id, title: title,
                                     runs: runs, metadata: metadata)
    }
}

public extension ParseResult {
    /// Creates a complete, reproducible record for one parse. The full source
    /// is deliberately retained so a saved bundle does not depend on an editor
    /// buffer or a grammar service still being available.
    func experimentRun(
        snapshot: SourceSnapshot,
        documentURI: String,
        grammar: GrammarArtifactIdentity,
        runID: String? = nil
    ) throws -> ParseExperimentRun {
        guard version == snapshot.version else {
            throw ExperimentContractError.inconsistentRevision
        }

        let document = try DocumentRevision(
            uri: documentURI, languageID: "pl0", revision: snapshot.version,
            coordinateSpace: .utf16, sourceLength: snapshot.text.utf16.count,
            sourceFingerprint: StableFingerprint.fnv1a64(snapshot.text))
        let source = try SourceArtifact(document: document, text: snapshot.text)
        let experimentTokens = try tokens.map { token in
            try ExperimentToken(
                id: token.id, kind: token.kind.rawValue, lexeme: token.lexeme,
                range: ExperimentRange(location: token.range.location,
                                       length: token.range.length),
                channel: token.kind == .endOfFile ? .endOfFile
                    : token.kind == .invalid ? .invalid : .source)
        }
        let tokenSnapshot = try TokenSnapshot(document: document, grammar: grammar,
                                              tokens: experimentTokens)
        let execution = try executionPath()
        let diagnosticEvidence = try diagnostics.map { diagnostic in
            let severity: ExperimentDiagnosticSeverity = switch diagnostic.severity {
            case .error: .error
            case .warning: .warning
            case .information: .information
            }
            return try ExperimentDiagnostic(
                id: diagnostic.id,
                severity: severity,
                message: diagnostic.message,
                range: ExperimentRange(location: diagnostic.range.location,
                                       length: diagnostic.range.length),
                expected: diagnostic.expected.map(\.rawValue))
        }
        let recoveryEdits = try recovery.events.map { event in
            switch event.action {
            case let .insert(kind, offset):
                try ExperimentRecoveryEdit(
                    sequence: event.sequence, kind: .insert,
                    tokenKind: kind.rawValue,
                    range: ExperimentRange(location: offset, length: 0),
                    cost: event.cost, diagnosticIDs: event.diagnosticIDs)
            case let .delete(token):
                try ExperimentRecoveryEdit(
                    sequence: event.sequence, kind: .delete,
                    tokenKind: token.kind.rawValue, tokenID: token.id,
                    range: ExperimentRange(location: token.range.location,
                                           length: token.range.length),
                    cost: event.cost, diagnosticIDs: event.diagnosticIDs)
            }
        }

        let reuse = try reuseEvidence(snapshot: snapshot)
        let operationMeasurements = try measurementsForExperiment()
        let status: ExperimentParseStatus = recovery.isClean && diagnostics.isEmpty
            ? .accepted : .recovered

        return try ParseExperimentRun(
            id: runID ?? "\(snapshot.version):\(parser.id)",
            source: source, grammar: grammar, tokenSnapshot: tokenSnapshot,
            execution: execution, disposition: .completed, status: status,
            diagnostics: diagnosticEvidence,
            recovery: RecoveryEvidence(edits: recoveryEdits), reuse: reuse,
            measurements: operationMeasurements,
            syntaxFingerprint: StableFingerprint.fnv1a64(root.outline()))
    }

    private func executionPath() throws -> EngineExecutionPath {
        let requested = try experimentEngine(parser)
        let fallbackReason: String?
        switch algorithmArtifact {
        case .lr(let artifact) where !artifact.recognition.accepted:
            fallbackReason = "SLR recognizer rejected the input; reference LL recovery produced the editor result."
        case .earley(let artifact) where !artifact.recognition.accepted:
            fallbackReason = "Earley recognizer rejected the input; reference LL recovery produced the editor result."
        case .lr where tokens.contains(where: { $0.kind == .invalid }),
             .earley where tokens.contains(where: { $0.kind == .invalid }):
            fallbackReason = "Lexical diagnostics required reference LL recovery."
        default:
            fallbackReason = nil
        }
        if let fallbackReason {
            let fallback = try ExperimentEngineIdentity(
                id: "reference-ll", displayName: "Reference LL",
                algorithm: "LL recursive descent", implementation: "ModEdit.PL0Language")
            return try EngineExecutionPath(requested: requested, effective: fallback,
                                           fallbackReason: fallbackReason)
        }
        return try EngineExecutionPath(requested: requested, effective: requested)
    }

    private func experimentEngine(_ descriptor: ParserDescriptor) throws -> ExperimentEngineIdentity {
        let algorithm = switch descriptor.id {
        case "reference-ll": "LL recursive descent"
        case "slr-1": "SLR(1)"
        case "earley": "Earley"
        default: descriptor.displayName
        }
        return try ExperimentEngineIdentity(
            id: descriptor.id, displayName: descriptor.displayName,
            algorithm: algorithm, implementation: "ModEdit.PL0Language")
    }

    private func reuseEvidence(snapshot: SourceSnapshot) throws -> ReuseEvidence {
        let lex = metrics.incrementalLexing
        let parsing = metrics.incrementalParsing
        var values = [try ReuseMeasurement(
            dimension: .tokens,
            reused: lex.reusedPrefixTokenCount + lex.reusedSuffixTokenCount,
            rebuilt: lex.generatedTokenCount,
            strategy: lex.incremental ? "restart-and-converge" : "full-tokenization")]
        values.append(try ReuseMeasurement(
            dimension: .syntaxNodes, reused: parsing.reusedNodeCount,
            rebuilt: parsing.parsedNodeCount,
            strategy: parsing.incremental ? "stable-token-region-cache" : "full-parse"))
        if case .earley(let artifact) = algorithmArtifact {
            values.append(try ReuseMeasurement(
                dimension: .chartColumns,
                reused: artifact.reusedChartColumnCount,
                rebuilt: max(0, artifact.recognition.consumedTokenCount + 1
                             - artifact.reusedChartColumnCount),
                strategy: artifact.reusedChartColumnCount > 0
                    ? "closed-prefix-chart" : "full-chart"))
        }
        let incremental = lex.incremental || parsing.incremental || {
            switch algorithmArtifact {
            case .lr(let artifact): artifact.reusedTokenCount > 0
            case .earley(let artifact): artifact.reusedChartColumnCount > 0
            case nil: false
            }
        }()
        let inferredBase = incremental
            ? (snapshot.edit?.baseVersion ?? (snapshot.version > 0 ? snapshot.version - 1 : 0))
            : nil
        return try ReuseEvidence(incremental: incremental,
                                 baseRevision: inferredBase,
                                 measurements: values)
    }

    private func measurementsForExperiment() throws -> [ExperimentMeasurement] {
        var values = [
            try ExperimentMeasurement(name: "sourceLength", value: UInt64(metrics.sourceLength), unit: "utf16CodeUnits"),
            try ExperimentMeasurement(name: "tokenCount", value: UInt64(metrics.tokenCount), unit: "tokens"),
            try ExperimentMeasurement(name: "lexingDuration", value: metrics.lexingNanoseconds, unit: "nanoseconds"),
            try ExperimentMeasurement(name: "parsingDuration", value: metrics.parsingNanoseconds, unit: "nanoseconds"),
            try ExperimentMeasurement(name: "recoveryCount", value: UInt64(metrics.recoveryCount), unit: "edits"),
        ]
        switch algorithmArtifact {
        case .lr(let artifact):
            values += [
                try ExperimentMeasurement(name: "configurations", value: UInt64(artifact.recognition.configurationCount), unit: "configurations"),
                try ExperimentMeasurement(name: "peakFrontier", value: UInt64(artifact.recognition.maximumFrontierSize), unit: "stackEntries"),
                try ExperimentMeasurement(name: "parserResumePrefix", value: UInt64(artifact.reusedTokenCount), unit: "tokens"),
            ]
        case .earley(let artifact):
            values += [
                try ExperimentMeasurement(name: "configurations", value: UInt64(artifact.recognition.configurationCount), unit: "chartItems"),
                try ExperimentMeasurement(name: "peakFrontier", value: UInt64(artifact.recognition.maximumFrontierSize), unit: "chartItems"),
            ]
            if let forest = artifact.forest {
                values += [
                    try ExperimentMeasurement(name: "forestNodes", value: UInt64(forest.nodes.count), unit: "nodes"),
                    try ExperimentMeasurement(name: "packedAlternatives", value: UInt64(forest.packedAlternativeCount), unit: "alternatives"),
                ]
            }
        case nil:
            break
        }
        return values
    }
}
