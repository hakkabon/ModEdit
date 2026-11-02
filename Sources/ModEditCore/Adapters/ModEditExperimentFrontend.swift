import PL0FrontendConformance

/// Headless entry point for the same adapter boundary used by the workbench UI.
public enum ModEditExperimentFrontend {
    public static func run() async throws -> PL0FrontendExperimentReport {
        try await PL0FrontendExperimentSuite.run(frontendID: "modedit")
    }
}
