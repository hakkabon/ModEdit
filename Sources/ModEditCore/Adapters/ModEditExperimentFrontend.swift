import IncrementalParsing
import PL0FrontendConformance

/// Headless entry point for the same adapter boundary used by the workbench UI.
public enum ModEditExperimentFrontend {
    public static func run() async throws -> PL0FrontendExperimentReport {
        try await PL0FrontendExperimentSuite.run(frontendID: "modedit")
    }

    /// Runs the language-kit-owned campaign without adding editor state or
    /// reinterpreting native reuse evidence.
    public static func runProductCampaign() async throws
        -> IncrementalMeasurementReport {
        try await PL0ProductCampaign.run()
    }
}
