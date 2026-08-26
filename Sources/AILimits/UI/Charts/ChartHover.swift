import SwiftUI
import Charts

/// Where the pointer is, translated into the chart's own x value.
struct HoverPoint: Equatable {
    var date: Date
    var location: CGPoint
}

extension View {
    /// Call site sugar: `.chartOverlayHover($state)` on a `Chart`.
    func chartOverlayHover(_ binding: Binding<HoverPoint?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let anchor = proxy.plotFrame else { binding.wrappedValue = nil; return }
                            let plot = geometry[anchor]
                            guard plot.contains(point),
                                  let date: Date = proxy.value(atX: point.x - plot.origin.x)
                            else { binding.wrappedValue = nil; return }
                            binding.wrappedValue = HoverPoint(date: date, location: point)
                        case .ended:
                            binding.wrappedValue = nil
                        }
                    }
            }
        }
    }

    /// Floats a tooltip beside the pointer, kept inside the chart's bounds.
    func chartTooltip<Content: View>(at hover: HoverPoint?,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay(alignment: .topLeading) {
            if let hover {
                GeometryReader { geometry in
                    ChartTooltip(content: content)
                        .fixedSize()
                        .alignmentGuide(.leading) { _ in 0 }
                        .offset(x: min(max(hover.location.x + 14, 0), max(geometry.size.width - 230, 0)),
                                y: max(hover.location.y - 44, 4))
                }
                .allowsHitTesting(false)
            }
        }
    }
}

struct ChartTooltip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) { content() }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.surface)
                    .shadow(color: .black.opacity(0.22), radius: 7, y: 2))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.gridline, lineWidth: 1))
    }
}

/// One "swatch — label — value" row inside a tooltip.
struct TooltipRow: View {
    var color: Color?
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            if let color {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            }
            Text(label).font(.system(size: 11))
            Spacer(minLength: 10)
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }
}
