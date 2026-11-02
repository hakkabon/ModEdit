import Foundation
import Darwin
import ModEditCore
import PL0FrontendConformance

@main
struct ModEditExperimentCLI {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "compare" {
            let reports = try arguments.dropFirst().map {
                try PL0FrontendExperimentReport.decode(Data(contentsOf: URL(fileURLWithPath: $0)))
            }
            let agreement = PL0FrontendExperimentSuite.compare(reports)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(agreement), as: UTF8.self))
            if !agreement.equivalent { exit(EXIT_FAILURE) }
            return
        }
        let report = try await ModEditExperimentFrontend.run()
        let data = try report.json()
        if let output = arguments.first {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
