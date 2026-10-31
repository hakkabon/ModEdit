import Foundation

/// Stable, transport-neutral interchange values shared by editors, grammar
/// tools, parser engines, language servers, and compiler experiments.
public enum LanguageExperimentProtocol {
    public static let schemaVersion = 1
    public static let fingerprintAlgorithm = "fnv1a64"
}

public enum ExperimentContractError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedSchema(Int)
    case emptyField(String)
    case invalidRange
    case invalidCount(String)
    case duplicateRunID(String)
    case duplicateTokenID(String)
    case mismatchedSourceFingerprint
    case mismatchedSourceLength
    case inconsistentRevision
    case invalidExecutionPath

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Language experiment schema \(version) is not supported."
        case .emptyField(let field): "The required field '\(field)' is empty."
        case .invalidRange: "A source range is invalid or exceeds its source revision."
        case .invalidCount(let field): "The count '\(field)' must not be negative."
        case .duplicateRunID(let id): "The experiment contains duplicate run ID '\(id)'."
        case .duplicateTokenID(let id): "The token snapshot contains duplicate stable ID '\(id)'."
        case .mismatchedSourceFingerprint: "The source text does not match its fingerprint."
        case .mismatchedSourceLength: "The source text does not match its declared length."
        case .inconsistentRevision: "Experiment components refer to different document revisions."
        case .invalidExecutionPath: "Fallback metadata is inconsistent with the effective parser engine."
        }
    }
}

public enum SourceCoordinateSpace: String, Codable, Hashable, Sendable {
    case utf8
    case utf16
    case unicodeScalars
}

public struct ExperimentRange: Codable, Hashable, Sendable {
    public let location: Int
    public let length: Int
    public var end: Int { location + length }

    public init(location: Int, length: Int) throws {
        guard location >= 0, length >= 0,
              !location.addingReportingOverflow(length).overflow else {
            throw ExperimentContractError.invalidRange
        }
        self.location = location
        self.length = length
    }
}

public struct DocumentRevision: Codable, Hashable, Sendable {
    public let uri: String
    public let languageID: String
    public let revision: UInt64
    public let coordinateSpace: SourceCoordinateSpace
    public let sourceLength: Int
    public let sourceFingerprint: String
    public let fingerprintAlgorithm: String

    public init(uri: String, languageID: String, revision: UInt64,
                coordinateSpace: SourceCoordinateSpace, sourceLength: Int,
                sourceFingerprint: String,
                fingerprintAlgorithm: String = LanguageExperimentProtocol.fingerprintAlgorithm) throws {
        try requireNonempty(uri, "document.uri")
        try requireNonempty(languageID, "document.languageID")
        try requireNonempty(sourceFingerprint, "document.sourceFingerprint")
        try requireNonempty(fingerprintAlgorithm, "document.fingerprintAlgorithm")
        guard sourceLength >= 0 else { throw ExperimentContractError.invalidCount("sourceLength") }
        self.uri = uri
        self.languageID = languageID
        self.revision = revision
        self.coordinateSpace = coordinateSpace
        self.sourceLength = sourceLength
        self.sourceFingerprint = sourceFingerprint
        self.fingerprintAlgorithm = fingerprintAlgorithm
    }
}

public struct SourceArtifact: Codable, Hashable, Sendable {
    public let document: DocumentRevision
    public let text: String

    public init(document: DocumentRevision, text: String) throws {
        guard measuredLength(text, in: document.coordinateSpace) == document.sourceLength else {
            throw ExperimentContractError.mismatchedSourceLength
        }
        guard StableFingerprint.fnv1a64(text) == document.sourceFingerprint,
              document.fingerprintAlgorithm == LanguageExperimentProtocol.fingerprintAlgorithm else {
            throw ExperimentContractError.mismatchedSourceFingerprint
        }
        self.document = document
        self.text = text
    }
}

/// Identifies the exact grammar artifact used by a parser invocation. IDs are
/// presentation-independent; the fingerprint detects stale or drifting data.
public struct GrammarArtifactIdentity: Codable, Hashable, Sendable {
    public struct ProductionProvenance: Codable, Hashable, Sendable {
        public let normalizedProductionID: String
        public let sourceProductionIDs: [String]

        public init(normalizedProductionID: String, sourceProductionIDs: [String]) throws {
            try requireNonempty(normalizedProductionID, "normalizedProductionID")
            self.normalizedProductionID = normalizedProductionID
            self.sourceProductionIDs = sourceProductionIDs.sorted()
        }
    }

    public let artifactID: String
    public let languageID: String
    public let revision: UInt64
    public let notation: String
    public let normalForm: String?
    public let fingerprint: String
    public let fingerprintAlgorithm: String
    public let provenance: [ProductionProvenance]

    public init(artifactID: String, languageID: String, revision: UInt64,
                notation: String, normalForm: String? = nil,
                fingerprint: String,
                fingerprintAlgorithm: String = LanguageExperimentProtocol.fingerprintAlgorithm,
                provenance: [ProductionProvenance] = []) throws {
        try requireNonempty(artifactID, "grammar.artifactID")
        try requireNonempty(languageID, "grammar.languageID")
        try requireNonempty(notation, "grammar.notation")
        try requireNonempty(fingerprint, "grammar.fingerprint")
        try requireNonempty(fingerprintAlgorithm, "grammar.fingerprintAlgorithm")
        self.artifactID = artifactID
        self.languageID = languageID
        self.revision = revision
        self.notation = notation
        self.normalForm = normalForm
        self.fingerprint = fingerprint
        self.fingerprintAlgorithm = fingerprintAlgorithm
        self.provenance = provenance.sorted { $0.normalizedProductionID < $1.normalizedProductionID }
    }

    public static func sourceArtifact(id: String, languageID: String,
                                      revision: UInt64, notation: String,
                                      source: String, normalForm: String? = nil) throws -> Self {
        try Self(artifactID: id, languageID: languageID, revision: revision,
                 notation: notation, normalForm: normalForm,
                 fingerprint: StableFingerprint.fnv1a64(source))
    }
}

public enum ExperimentTokenChannel: String, Codable, Hashable, Sendable {
    case source, trivia, invalid, endOfFile
}

public struct ExperimentToken: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let lexeme: String
    public let range: ExperimentRange
    public let channel: ExperimentTokenChannel

    public init(id: String, kind: String, lexeme: String,
                range: ExperimentRange, channel: ExperimentTokenChannel) throws {
        try requireNonempty(id, "token.id")
        try requireNonempty(kind, "token.kind")
        self.id = id
        self.kind = kind
        self.lexeme = lexeme
        self.range = range
        self.channel = channel
    }
}

public struct TokenSnapshot: Codable, Hashable, Sendable {
    public let document: DocumentRevision
    public let grammar: GrammarArtifactIdentity
    public let tokens: [ExperimentToken]

    public init(document: DocumentRevision, grammar: GrammarArtifactIdentity,
                tokens: [ExperimentToken]) throws {
        guard document.languageID == grammar.languageID else {
            throw ExperimentContractError.inconsistentRevision
        }
        var identities = Set<String>()
        for token in tokens {
            guard token.range.end <= document.sourceLength else {
                throw ExperimentContractError.invalidRange
            }
            guard identities.insert(token.id).inserted else {
                throw ExperimentContractError.duplicateTokenID(token.id)
            }
        }
        self.document = document
        self.grammar = grammar
        self.tokens = tokens
    }
}

public struct ExperimentEngineIdentity: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let algorithm: String
    public let implementation: String

    public init(id: String, displayName: String, algorithm: String,
                implementation: String) throws {
        try requireNonempty(id, "engine.id")
        try requireNonempty(displayName, "engine.displayName")
        try requireNonempty(algorithm, "engine.algorithm")
        try requireNonempty(implementation, "engine.implementation")
        self.id = id
        self.displayName = displayName
        self.algorithm = algorithm
        self.implementation = implementation
    }
}

public struct EngineExecutionPath: Codable, Hashable, Sendable {
    public let requested: ExperimentEngineIdentity
    public let effective: ExperimentEngineIdentity
    public let fallbackReason: String?

    public init(requested: ExperimentEngineIdentity,
                effective: ExperimentEngineIdentity,
                fallbackReason: String? = nil) throws {
        if requested.id == effective.id, fallbackReason != nil {
            throw ExperimentContractError.invalidExecutionPath
        }
        if requested.id != effective.id, fallbackReason?.isEmpty != false {
            throw ExperimentContractError.invalidExecutionPath
        }
        self.requested = requested
        self.effective = effective
        self.fallbackReason = fallbackReason
    }

    public var usedFallback: Bool { requested.id != effective.id }
}

public enum ExperimentOperationDisposition: String, Codable, Hashable, Sendable {
    case completed, unsupported, limited, cancelled, failed
}

public enum ExperimentParseStatus: String, Codable, Hashable, Sendable {
    case accepted, recovered, rejected
}

public enum ExperimentDiagnosticSeverity: String, Codable, Hashable, Sendable {
    case error, warning, information
}

public struct ExperimentDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let severity: ExperimentDiagnosticSeverity
    public let message: String
    public let range: ExperimentRange
    public let expected: [String]

    public init(id: String, severity: ExperimentDiagnosticSeverity,
                message: String, range: ExperimentRange,
                expected: [String] = []) throws {
        try requireNonempty(id, "diagnostic.id")
        try requireNonempty(message, "diagnostic.message")
        self.id = id
        self.severity = severity
        self.message = message
        self.range = range
        self.expected = expected.sorted()
    }
}

public enum ExperimentRecoveryKind: String, Codable, Hashable, Sendable {
    case insert, delete, skip
}

public struct ExperimentRecoveryEdit: Codable, Hashable, Sendable {
    public let sequence: Int
    public let kind: ExperimentRecoveryKind
    public let tokenKind: String
    public let tokenID: String?
    public let range: ExperimentRange
    public let cost: Int
    public let diagnosticIDs: [String]

    public init(sequence: Int, kind: ExperimentRecoveryKind, tokenKind: String,
                tokenID: String? = nil, range: ExperimentRange, cost: Int,
                diagnosticIDs: [String] = []) throws {
        guard sequence >= 0 else { throw ExperimentContractError.invalidCount("recovery.sequence") }
        guard cost >= 0 else { throw ExperimentContractError.invalidCount("recovery.cost") }
        try requireNonempty(tokenKind, "recovery.tokenKind")
        self.sequence = sequence
        self.kind = kind
        self.tokenKind = tokenKind
        self.tokenID = tokenID
        self.range = range
        self.cost = cost
        self.diagnosticIDs = diagnosticIDs.sorted()
    }
}

public struct RecoveryEvidence: Codable, Hashable, Sendable {
    public let edits: [ExperimentRecoveryEdit]
    public let totalCost: Int

    public init(edits: [ExperimentRecoveryEdit]) {
        self.edits = edits.sorted { $0.sequence < $1.sequence }
        totalCost = edits.reduce(0) { $0 + $1.cost }
    }
}

/// Reuse is intentionally multidimensional. Token, parser-state, syntax,
/// forest, and semantic reuse are never combined into a misleading percentage.
public enum ReuseDimension: String, Codable, Hashable, Sendable {
    case tokens, parserStates, syntaxNodes, chartColumns, forestNodes, semanticNodes
}

public struct ReuseMeasurement: Codable, Hashable, Sendable {
    public let dimension: ReuseDimension
    public let reused: Int
    public let rebuilt: Int
    /// `nil` means the producer cannot measure invalidation for this dimension.
    public let invalidated: Int?
    public let strategy: String

    public init(dimension: ReuseDimension, reused: Int, rebuilt: Int,
                invalidated: Int? = nil, strategy: String) throws {
        guard reused >= 0 else { throw ExperimentContractError.invalidCount("reuse.reused") }
        guard rebuilt >= 0 else { throw ExperimentContractError.invalidCount("reuse.rebuilt") }
        if let invalidated, invalidated < 0 {
            throw ExperimentContractError.invalidCount("reuse.invalidated")
        }
        try requireNonempty(strategy, "reuse.strategy")
        self.dimension = dimension
        self.reused = reused
        self.rebuilt = rebuilt
        self.invalidated = invalidated
        self.strategy = strategy
    }
}

public struct ReuseEvidence: Codable, Hashable, Sendable {
    public let incremental: Bool
    public let baseRevision: UInt64?
    public let measurements: [ReuseMeasurement]

    public init(incremental: Bool, baseRevision: UInt64?,
                measurements: [ReuseMeasurement]) throws {
        if incremental != (baseRevision != nil) {
            throw ExperimentContractError.inconsistentRevision
        }
        self.incremental = incremental
        self.baseRevision = baseRevision
        self.measurements = measurements.sorted { $0.dimension.rawValue < $1.dimension.rawValue }
    }
}

public struct ExperimentMeasurement: Codable, Hashable, Sendable {
    public let name: String
    public let value: UInt64
    public let unit: String

    public init(name: String, value: UInt64, unit: String) throws {
        try requireNonempty(name, "measurement.name")
        try requireNonempty(unit, "measurement.unit")
        self.name = name
        self.value = value
        self.unit = unit
    }
}

public struct ParseExperimentRun: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let source: SourceArtifact
    public let grammar: GrammarArtifactIdentity
    public let tokenSnapshot: TokenSnapshot
    public let execution: EngineExecutionPath
    public let disposition: ExperimentOperationDisposition
    public let status: ExperimentParseStatus
    public let diagnostics: [ExperimentDiagnostic]
    public let recovery: RecoveryEvidence
    public let reuse: ReuseEvidence
    public let measurements: [ExperimentMeasurement]
    public let syntaxFingerprint: String?

    public init(id: String, source: SourceArtifact,
                grammar: GrammarArtifactIdentity, tokenSnapshot: TokenSnapshot,
                execution: EngineExecutionPath,
                disposition: ExperimentOperationDisposition,
                status: ExperimentParseStatus,
                diagnostics: [ExperimentDiagnostic], recovery: RecoveryEvidence,
                reuse: ReuseEvidence, measurements: [ExperimentMeasurement] = [],
                syntaxFingerprint: String? = nil) throws {
        try requireNonempty(id, "run.id")
        guard source.document == tokenSnapshot.document,
              grammar == tokenSnapshot.grammar else {
            throw ExperimentContractError.inconsistentRevision
        }
        for diagnostic in diagnostics where diagnostic.range.end > source.document.sourceLength {
            throw ExperimentContractError.invalidRange
        }
        self.id = id
        self.source = source
        self.grammar = grammar
        self.tokenSnapshot = tokenSnapshot
        self.execution = execution
        self.disposition = disposition
        self.status = status
        self.diagnostics = diagnostics
        self.recovery = recovery
        self.reuse = reuse
        self.measurements = measurements.sorted { $0.name < $1.name }
        self.syntaxFingerprint = syntaxFingerprint
    }
}

/// A reproducible edit sequence or engine comparison. Every run retains its
/// complete source, exact grammar identity, tokens, result evidence, and costs.
public struct LanguageExperimentBundle: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let title: String
    public let runs: [ParseExperimentRun]
    public let metadata: [String: String]

    public init(id: String, title: String, runs: [ParseExperimentRun],
                metadata: [String: String] = [:]) throws {
        try requireNonempty(id, "bundle.id")
        try requireNonempty(title, "bundle.title")
        var ids = Set<String>()
        for run in runs where !ids.insert(run.id).inserted {
            throw ExperimentContractError.duplicateRunID(run.id)
        }
        schemaVersion = LanguageExperimentProtocol.schemaVersion
        self.id = id
        self.title = title
        self.runs = runs
        self.metadata = metadata
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, id, title, runs, metadata }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == LanguageExperimentProtocol.schemaVersion else {
            throw ExperimentContractError.unsupportedSchema(version)
        }
        try self.init(
            id: values.decode(String.self, forKey: .id),
            title: values.decode(String.self, forKey: .title),
            runs: values.decode([ParseExperimentRun].self, forKey: .runs),
            metadata: values.decode([String: String].self, forKey: .metadata))
    }

    public func json(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(json: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: json)
    }

    private func validate() throws {
        try requireNonempty(id, "bundle.id")
        try requireNonempty(title, "bundle.title")
        var runIDs = Set<String>()
        for run in runs {
            guard runIDs.insert(run.id).inserted else {
                throw ExperimentContractError.duplicateRunID(run.id)
            }
            try validate(run)
        }
    }

    private func validate(_ run: ParseExperimentRun) throws {
        try requireNonempty(run.id, "run.id")
        let document = run.source.document
        try requireNonempty(document.uri, "document.uri")
        try requireNonempty(document.languageID, "document.languageID")
        guard document.sourceLength >= 0 else {
            throw ExperimentContractError.invalidCount("sourceLength")
        }
        guard measuredLength(run.source.text, in: document.coordinateSpace)
                == document.sourceLength else {
            throw ExperimentContractError.mismatchedSourceLength
        }
        guard document.fingerprintAlgorithm == LanguageExperimentProtocol.fingerprintAlgorithm,
              StableFingerprint.fnv1a64(run.source.text) == document.sourceFingerprint else {
            throw ExperimentContractError.mismatchedSourceFingerprint
        }

        try requireNonempty(run.grammar.artifactID, "grammar.artifactID")
        try requireNonempty(run.grammar.languageID, "grammar.languageID")
        try requireNonempty(run.grammar.notation, "grammar.notation")
        try requireNonempty(run.grammar.fingerprint, "grammar.fingerprint")
        guard run.source.document == run.tokenSnapshot.document,
              run.grammar == run.tokenSnapshot.grammar,
              document.languageID == run.grammar.languageID else {
            throw ExperimentContractError.inconsistentRevision
        }

        var tokenIDs = Set<String>()
        for token in run.tokenSnapshot.tokens {
            try requireNonempty(token.id, "token.id")
            try requireNonempty(token.kind, "token.kind")
            guard token.range.location >= 0, token.range.length >= 0,
                  !token.range.location.addingReportingOverflow(token.range.length).overflow,
                  token.range.end <= document.sourceLength else {
                throw ExperimentContractError.invalidRange
            }
            guard tokenIDs.insert(token.id).inserted else {
                throw ExperimentContractError.duplicateTokenID(token.id)
            }
        }

        try requireNonempty(run.execution.requested.id, "engine.requested.id")
        try requireNonempty(run.execution.effective.id, "engine.effective.id")
        if run.execution.requested.id == run.execution.effective.id {
            guard run.execution.fallbackReason == nil else {
                throw ExperimentContractError.invalidExecutionPath
            }
        } else if run.execution.fallbackReason?.isEmpty != false {
            throw ExperimentContractError.invalidExecutionPath
        }

        for diagnostic in run.diagnostics {
            try requireNonempty(diagnostic.id, "diagnostic.id")
            try requireNonempty(diagnostic.message, "diagnostic.message")
            guard diagnostic.range.location >= 0, diagnostic.range.length >= 0,
                  !diagnostic.range.location.addingReportingOverflow(diagnostic.range.length).overflow,
                  diagnostic.range.end <= document.sourceLength else {
                throw ExperimentContractError.invalidRange
            }
        }
        for edit in run.recovery.edits {
            guard edit.sequence >= 0 else {
                throw ExperimentContractError.invalidCount("recovery.sequence")
            }
            guard edit.cost >= 0 else {
                throw ExperimentContractError.invalidCount("recovery.cost")
            }
            guard edit.range.location >= 0, edit.range.length >= 0,
                  !edit.range.location.addingReportingOverflow(edit.range.length).overflow,
                  edit.range.end <= document.sourceLength else {
                throw ExperimentContractError.invalidRange
            }
        }
        guard run.recovery.totalCost == run.recovery.edits.reduce(0, { $0 + $1.cost }) else {
            throw ExperimentContractError.invalidCount("recovery.totalCost")
        }
        guard run.reuse.incremental == (run.reuse.baseRevision != nil) else {
            throw ExperimentContractError.inconsistentRevision
        }
        if let baseRevision = run.reuse.baseRevision,
           baseRevision >= document.revision {
            throw ExperimentContractError.inconsistentRevision
        }
        for measurement in run.reuse.measurements {
            guard measurement.reused >= 0, measurement.rebuilt >= 0,
                  measurement.invalidated.map({ $0 >= 0 }) ?? true else {
                throw ExperimentContractError.invalidCount("reuse.measurement")
            }
            try requireNonempty(measurement.strategy, "reuse.strategy")
        }
        for measurement in run.measurements {
            try requireNonempty(measurement.name, "measurement.name")
            try requireNonempty(measurement.unit, "measurement.unit")
        }
    }
}

public enum StableFingerprint {
    /// The ecosystem's small, deterministic interchange fingerprint. This is
    /// an identity checksum, not a cryptographic signature.
    public static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

private func requireNonempty(_ value: String, _ field: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ExperimentContractError.emptyField(field)
    }
}

private func measuredLength(_ text: String, in coordinateSpace: SourceCoordinateSpace) -> Int {
    switch coordinateSpace {
    case .utf8: text.utf8.count
    case .utf16: text.utf16.count
    case .unicodeScalars: text.unicodeScalars.count
    }
}
