#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import DOTLanguage
import SwiftLayout

struct DOTPreviewDrawing: Sendable {
    struct Node: Identifiable, Sendable {
        let id: UInt64
        let source: DOTGraph.Node
        let size: CGSize
        let center: CGPoint
    }

    let nodes: [Node]
    let routes: [FfiEdgeRoute]
    let edgeLabels: [UInt64: String]
    let directed: Bool
    let bounds: CGRect
}

/// Serializes the synchronous native layout calls off the UI actor.
actor DOTPreviewLayout {
    static let maximumNodes = 200
    static let maximumEdges = 400

    enum Failure: LocalizedError {
        case tooLarge

        var errorDescription: String? {
            "DOT preview supports up to \(DOTPreviewLayout.maximumNodes) nodes and \(DOTPreviewLayout.maximumEdges) edges."
        }
    }

    func draw(_ graph: DOTGraph) throws -> DOTPreviewDrawing {
        try Task.checkCancellation()
        guard graph.nodes.count <= Self.maximumNodes, graph.edges.count <= Self.maximumEdges else {
            throw Failure.tooLarge
        }
        guard !graph.nodes.isEmpty else {
            return .init(nodes: [], routes: [], edgeLabels: [:], directed: graph.directed, bounds: .zero)
        }

        var nodeIDs: [String: UInt64] = [:]
        let nodes = graph.nodes.enumerated().map { index, node in
            let id = UInt64(index)
            nodeIDs[node.id] = id
            let size = Self.nodeSize(for: node.label)
            return FfiNode(id: id, width: Float(size.width), height: Float(size.height),
                           rankHint: nil, rankConstraint: .preferred)
        }
        var labels: [UInt64: String] = [:]
        let edges = graph.edges.enumerated().compactMap { index, edge -> FfiEdge? in
            guard let from = nodeIDs[edge.from], let to = nodeIDs[edge.to] else { return nil }
            let id = UInt64(index)
            let label = edge.label.map { String($0.prefix(160)) }
            if let label, !label.isEmpty { labels[id] = label }
            return FfiEdge(id: id, from: from, to: to,
                           labelWidth: labels[id].map { Float(Self.textWidth($0, size: 11) + 10) },
                           labelHeight: labels[id].map { _ in 22 })
        }
        let config = FfiConfig(hGap: 32, vGap: 52, relaxPasses: 2, sweeps: 4,
                               algorithm: .brandesKopf, routing: .bezier,
                               direction: graph.leftToRight ? .leftToRight : .topToBottom)
        let layout = try SwiftLayout.layout(nodes: nodes, edges: edges, config: config)
        try Task.checkCancellation()

        let positioned = layout.positions.compactMap { position -> DOTPreviewDrawing.Node? in
            guard let index = Int(exactly: position.id), nodes.indices.contains(index) else { return nil }
            return .init(id: position.id, source: graph.nodes[index],
                         size: CGSize(width: CGFloat(nodes[index].width), height: CGFloat(nodes[index].height)),
                         center: CGPoint(x: CGFloat(position.x), y: CGFloat(position.y)))
        }
        var bounds = CGRect(x: CGFloat(layout.bounds.minX), y: CGFloat(layout.bounds.minY),
                            width: CGFloat(layout.bounds.width), height: CGFloat(layout.bounds.height))
        for route in layout.routes {
            guard let position = route.labelPosition, let label = labels[route.id] else { continue }
            let width = Self.textWidth(label, size: 11) + 10
            bounds = bounds.union(CGRect(x: CGFloat(position.x) - width / 2,
                                         y: CGFloat(position.y) - 11, width: width, height: 22))
        }
        return .init(nodes: positioned, routes: layout.routes, edgeLabels: labels,
                     directed: graph.directed, bounds: bounds)
    }

    static func nodeSize(for label: String) -> CGSize {
        let lines = label.prefix(160).split(separator: "\n", omittingEmptySubsequences: false).prefix(3)
        let width = lines.map { textWidth(String($0), size: 13) }.max() ?? 0
        return CGSize(width: max(54, width + 22), height: CGFloat(max(1, lines.count)) * 17 + 14)
    }

    private static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: size)
        #else
        let font = NSFont.systemFont(ofSize: size)
        #endif
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return min(220, measured.width.rounded(.up))
    }
}
