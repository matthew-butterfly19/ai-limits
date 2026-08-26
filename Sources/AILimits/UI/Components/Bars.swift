import SwiftUI

/// A limit meter. The percentage is always printed beside it, so the colour
/// escalation is a second cue rather than the only one.
struct MeterBar: View {
    var percent: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.gridline)
                Capsule()
                    .fill(Palette.severity(percent))
                    .frame(width: max(height, geometry.size.width * min(percent, 100) / 100))
            }
        }
        .frame(height: height)
        .accessibilityLabel("wykorzystanie \(Format.percent(percent))")
    }
}

/// Proportional segments in one bar, separated by a 2 px gap of the surface so
/// neighbouring fills never touch.
struct StackedBar: View {
    struct Segment: Identifiable {
        var id: String
        var value: Int
        var color: Color
        var label: String
    }

    var segments: [Segment]
    var height: CGFloat = 10

    private var total: Int { max(segments.reduce(0) { $0 + $1.value }, 1) }

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let available = max(geometry.size.width - gap * CGFloat(max(segments.count - 1, 0)), 1)
            HStack(spacing: gap) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.color)
                        .frame(width: max(2, available * CGFloat(segment.value) / CGFloat(total)))
                        .help("\(segment.label): \(Format.tokensFull(segment.value))")
                }
            }
        }
        .frame(height: height)
    }
}

/// One row of the thread or model list: a label, a proportional bar, a number.
struct BarRow: View {
    var title: String
    var subtitle: String?
    var value: Int
    var fraction: Double
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 11))
                Spacer(minLength: 6)
                Text(Format.tokens(value))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
            .frame(height: 4)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
        .help("\(title) — \(Format.tokensFull(value)) tokenów")
    }
}

/// Small rounded label for a project, model or plan name.
struct Chip: View {
    var text: String
    var color: Color = Palette.muted

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(color)
    }
}
