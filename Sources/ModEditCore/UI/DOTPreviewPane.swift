import DOTLanguage
import IncrementalParsing
import SwiftLayout
import SwiftUI

struct DOTPreviewDisplay {
    private(set) var revision: UInt64?
    private(set) var drawing: DOTPreviewDrawing?
    private(set) var message: String?

    mutating func show(_ drawing: DOTPreviewDrawing, revision: UInt64) {
        self.drawing = drawing
        self.revision = revision
        message = drawing.nodes.isEmpty ? "This graph has no nodes." : nil
    }

    mutating func report(_ message: String) {
        self.message = drawing?.nodes.isEmpty == false
            ? "Showing the previous graph. \(message)" : message
    }

    func canReveal(at currentRevision: UInt64) -> Bool {
        revision == currentRevision
    }
}

@MainActor
struct DOTPreviewPane: View {
    @ObservedObject var model: EditorModel
    @State private var session = DOTProviderSession()
    @State private var layout = DOTPreviewLayout()
    @State private var display = DOTPreviewDisplay()

    var body: some View {
        VStack(spacing: 0) {
            if let message = display.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            if let drawing = display.drawing, !drawing.nodes.isEmpty {
                graph(drawing)
            } else if display.message == nil {
                ProgressView("Laying out graph…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: model.textRevision) {
            let revision = model.textRevision
            await refresh(revision: revision)
        }
    }

    private func refresh(revision: UInt64) async {
        do {
            try await Task.sleep(for: .milliseconds(250))
            guard isCurrent(revision) else { return }
            guard let text = model.previewSnapshot(upTo: 65_536) else {
                display.report("DOT preview is limited to 65,536 UTF-16 units.")
                return
            }
            let preview = try await session.analyzeGraph(.init(text: text, revision: .init(revision)))
            guard isCurrent(revision) else { return }
            switch preview {
            case .graph(let graph):
                let drawing = try await layout.draw(graph)
                guard isCurrent(revision) else { return }
                display.show(drawing, revision: revision)
            case .invalid:
                display.report("Check Problems for the current DOT errors.")
            case .unsupported(let message):
                display.report(message)
            }
        } catch {
            if isCurrent(revision) { display.report(error.localizedDescription) }
        }
    }

    private func isCurrent(_ revision: UInt64) -> Bool {
        !Task.isCancelled && model.format is DOTFormat && model.textRevision == revision
            && model.documentTextGeneration == revision
    }

    private func graph(_ drawing: DOTPreviewDrawing) -> some View {
        GeometryReader { viewport in
            let width = max(viewport.size.width, drawing.bounds.width + 48)
            let height = max(viewport.size.height, drawing.bounds.height + 48)
            let offset = CGPoint(x: width / 2 - drawing.bounds.midX,
                                 y: height / 2 - drawing.bounds.midY)
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Canvas { context, _ in
                        var context = context
                        context.translateBy(x: offset.x, y: offset.y)
                        for route in drawing.routes { draw(route, directed: drawing.directed, in: context) }
                    }
                    ForEach(drawing.routes, id: \.id) { route in
                        if let label = drawing.edgeLabels[route.id], let center = route.labelPosition {
                            Text(label)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .frame(maxWidth: 220)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .fixedSize()
                                .position(x: CGFloat(center.x) + offset.x, y: CGFloat(center.y) + offset.y)
                        }
                    }
                    ForEach(drawing.nodes) { node in
                        Button {
                            guard display.canReveal(at: model.documentTextGeneration),
                                  model.format is DOTFormat else { return }
                            model.revealSourceRange(node.source.range)
                        } label: {
                            Text(String(node.source.label.prefix(160)))
                                .font(.system(size: 13))
                                .lineLimit(3)
                                .padding(.horizontal, 8)
                                .frame(width: node.size.width, height: node.size.height)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.55)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!display.canReveal(at: model.textRevision))
                        .accessibilityLabel(node.source.label.isEmpty ? node.source.id : node.source.label)
                        .help("Reveal \(node.source.id) in source")
                        .position(x: node.center.x + offset.x, y: node.center.y + offset.y)
                    }
                }
                .frame(width: width, height: height)
            }
        }
    }

    private nonisolated func draw(_ route: FfiEdgeRoute, directed: Bool, in context: GraphicsContext) {
        var path = Path()
        for segment in route.segments {
            switch segment {
            case .line(let start, let end):
                path.move(to: Self.point(start))
                path.addLine(to: Self.point(end))
            case .cubicCurve(let start, let control1, let control2, let end):
                path.move(to: Self.point(start))
                path.addCurve(to: Self.point(end), control1: Self.point(control1), control2: Self.point(control2))
            }
        }
        context.stroke(path, with: .color(.secondary), lineWidth: 1.5)
        if directed, let arrow = route.arrowhead {
            var tip = Path()
            tip.move(to: Self.point(arrow.tip))
            tip.addLine(to: Self.point(arrow.left))
            tip.addLine(to: Self.point(arrow.right))
            tip.closeSubpath()
            context.fill(tip, with: .color(.secondary))
        }
    }

    private nonisolated static func point(_ value: FfiPoint) -> CGPoint {
        CGPoint(x: CGFloat(value.x), y: CGFloat(value.y))
    }
}
