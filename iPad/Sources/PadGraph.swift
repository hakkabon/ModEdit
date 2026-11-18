import IncrementalParsing
import SwiftLayout
import SwiftUI

struct PadGraph: View {
    let drawing: DOTPreviewDrawing
    let reveal: (SourceRange) -> Void

    var body: some View {
        GeometryReader { viewport in
            let width = max(viewport.size.width, drawing.bounds.width + 48)
            let height = max(viewport.size.height, drawing.bounds.height + 48)
            let offset = CGPoint(x: width / 2 - drawing.bounds.midX, y: height / 2 - drawing.bounds.midY)
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Canvas { context, _ in
                        context.translateBy(x: offset.x, y: offset.y)
                        for route in drawing.routes {
                            var path = Path()
                            for segment in route.segments {
                                switch segment {
                                case .line(let start, let end):
                                    path.move(to: point(start))
                                    path.addLine(to: point(end))
                                case .cubicCurve(let start, let c1, let c2, let end):
                                    path.move(to: point(start))
                                    path.addCurve(to: point(end), control1: point(c1), control2: point(c2))
                                }
                            }
                            context.stroke(path, with: .color(.secondary), lineWidth: 1.5)
                            if drawing.directed, let arrow = route.arrowhead {
                                var tip = Path()
                                tip.move(to: point(arrow.tip))
                                tip.addLine(to: point(arrow.left))
                                tip.addLine(to: point(arrow.right))
                                tip.closeSubpath()
                                context.fill(tip, with: .color(.secondary))
                            }
                        }
                    }
                    ForEach(drawing.routes, id: \.id) { route in
                        if let label = drawing.edgeLabels[route.id], let center = route.labelPosition {
                            Text(label).font(.caption).padding(4)
                                .background(.regularMaterial).fixedSize()
                                .position(x: CGFloat(center.x) + offset.x, y: CGFloat(center.y) + offset.y)
                        }
                    }
                    ForEach(drawing.nodes) { node in
                        Button { reveal(node.source.range) } label: {
                            Text(String(node.source.label.prefix(160))).font(.system(size: 13))
                                .lineLimit(3)
                                .frame(width: node.size.width, height: node.size.height)
                                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.tint))
                        }.buttonStyle(.plain)
                            .position(x: node.center.x + offset.x, y: node.center.y + offset.y)
                    }
                }.frame(width: width, height: height)
            }
        }
    }

    private func point(_ value: FfiPoint) -> CGPoint {
        CGPoint(x: CGFloat(value.x), y: CGFloat(value.y))
    }
}
