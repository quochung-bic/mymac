import MyMacCore
import SwiftUI

/// The type scale.
///
/// macOS renders `.caption`, `.caption2` and `.footnote` at 10 pt, which is
/// below what is comfortably legible for interface text — especially for the
/// dimmed secondary colours this app uses. Nothing here goes under 11 pt, and
/// the shrink floors on `minimumScaleFactor` are set so a scaled label can
/// never fall below it either.
extension Font {
    /// The system UI font at an exact point size, registered against a text
    /// style so it still moves with System Settings → Accessibility → Display →
    /// Text Size. `Font.system(size:)` is frozen at whatever number is written
    /// beside it, which meant the whole app ignored that setting.
    ///
    /// If the face ever stops resolving under this name, SwiftUI falls back to
    /// the system font at the same size — today's behaviour exactly, so the
    /// worst case is no scaling rather than a wrong typeface.
    private static func ui(_ size: CGFloat, relativeTo style: TextStyle) -> Font {
        .custom(".AppleSystemUIFont", size: size, relativeTo: style)
    }

    /// Secondary labels: tile captions, units, explanatory notes.
    static let note = ui(11, relativeTo: .footnote)
    /// Section headers inside a card.
    static let sectionLabel = ui(11, relativeTo: .footnote).weight(.semibold)
    /// Pill badges.
    static let badge = ui(11, relativeTo: .footnote).weight(.medium)
    /// Numbers a tile leads with. Rounded, which `Font.custom` cannot carry, so
    /// this one keeps the fixed system face — a tile value is a number rather
    /// than reading matter, and `minimumScaleFactor` already governs it.
    static let tileValue = Font.system(size: 15, weight: .medium, design: .rounded)
    /// Axis-style labels, the smallest text in the app.
    static let axisLabel = ui(11, relativeTo: .caption)
}

/// A plain card. Native materials and system colours only, so the app follows
/// the user's appearance and accent settings without any theming of its own.
struct Card<Content: View>: View {
    let title: String
    var symbol: String?
    var accessory: String?
    /// Cards on the dashboard share the height of their row so the grid lines
    /// up; cards stacked in a scrolling detail page size to their content.
    var fillsHeight = false
    /// When set, the title becomes a link to wherever the card summarises —
    /// clicking "Storage" on the dashboard should take you to Storage.
    var onOpen: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let onOpen {
                    CardTitleLink(title: title, symbol: symbol, action: onOpen)
                } else {
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let accessory {
                    Text(accessory)
                        .font(.note)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        // The accessory is the part that gives way. A card whose
                        // own name is cut to "Stor…" has lost the more important
                        // half of its header.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity,
               maxHeight: fillsHeight ? .infinity : nil,
               alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

/// A horizontal meter. Deliberately monochrome until a value is genuinely
/// worth attention — a dashboard that is red all the time teaches the user to
/// ignore it.
struct MeterBar: View {
    let fraction: Double
    var tint: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                Capsule()
                    .fill(tint ?? Color.accentColor)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
        .accessibilityValue(Format.percent(fraction))
    }
}

/// A filled line chart drawn with `Canvas`: one draw call per update, no view
/// tree per sample, no animation.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor
    /// When nil the chart autoscales to its own maximum.
    var maximum: Double?
    /// What VoiceOver should say. Left nil where the chart sits beside the
    /// headline number it plots — announcing "43 percent" twice is worse than
    /// once — and set where the trend is the only thing being shown.
    var accessibilityDescription: String?
    /// Opacity of the gradient under the line. The default suits a value that
    /// spends most of its time near zero; a value that sits at 85 % fills the
    /// whole card, so those charts use a much fainter wash to stay a chart
    /// rather than becoming a solid block.
    var fillOpacity: Double = 0.28

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard values.count > 1 else { return }
            let peak = max(maximum ?? values.max() ?? 1, 0.0001)
            let step = size.width / CGFloat(values.count - 1)

            var line = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * step
                let y = size.height - CGFloat(min(1, max(0, value / peak))) * size.height
                if index == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            if fillOpacity > 0 {
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()

                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(fillOpacity), tint.opacity(fillOpacity * 0.07)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
            }
            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
        // No `drawingGroup()`: `Canvas` already renders in one pass, and
        // forcing an extra offscreen buffer here made a whole window fail to
        // composite when the chart was given an unbounded height.
        .accessibilityElement()
        .accessibilityHidden(accessibilityDescription == nil)
        .accessibilityLabel(accessibilityDescription ?? "")
        .accessibilityValue(trendDescription)
    }

    /// A line has no value a screen reader can read out, so it is described:
    /// where it is now, and where it has been.
    private var trendDescription: String {
        guard let latest = values.last, let peak = values.max() else { return "" }
        let scale = maximum ?? peak
        guard scale > 0 else { return "" }
        return "now \(Format.percent(latest / scale)) of peak, peak \(Format.percent(peak / scale))"
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var emphasis: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .fontWeight(emphasis ? .semibold : .regular)
        }
        .font(.callout)
    }
}

struct PressureBadge: View {
    let pressure: MemoryPressure

    var body: some View {
        Text(pressure.label)
            .font(.badge)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            // Never let the label compress: a truncated "Moder…" is worse than
            // a narrower meter beside it.
            .fixedSize()
            // One word is the kernel's vocabulary. "Moderate" says nothing to
            // anyone who has not read what the kernel means by it, so the badge
            // explains itself on hover rather than sitting there as a riddle.
            .help(pressure.explanation)
            .accessibilityLabel(pressure.explanation)
    }

    private var color: Color {
        switch pressure {
        case .low: .secondary
        case .moderate: .orange
        case .high: .red
        }
    }
}

extension Color {
    /// Usage colouring: neutral until it matters.
    static func forUsage(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: .accentColor
        case ..<0.90: .orange
        default: .red
        }
    }
}

/// A menu row that behaves like a real AppKit menu item: full-width highlight
/// that follows the pointer, symbol on the left, shortcut on the right.
struct MenuActionRow: View {
    /// The colour AppKit uses for the text of a highlighted menu item. Hard
    /// coding white was fine against the default blue accent and unreadable
    /// against a light one — and the accent is the user's choice, not ours.
    static let highlightedText = Color(nsColor: .selectedMenuItemTextColor)

    let title: String
    let symbol: String
    let shortcut: Character?
    let action: () -> Void

    @State private var isHighlighted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .frame(width: 15)
                Text(title)
                Spacer(minLength: 10)
                if let shortcut {
                    Text("⌘\(String(shortcut).uppercased())")
                        .font(.note)
                        .foregroundStyle(isHighlighted ? Self.highlightedText.opacity(0.7) : Color.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Self.highlightedText) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHighlighted = $0 }
        .modifier(OptionalShortcut(key: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: Character?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

/// A single bar broken into proportional segments.
///
/// Used for memory, where the interesting question is not "how full" but "full
/// of what" — a plain percentage hides the difference between a machine holding
/// file cache it can drop instantly and one that is genuinely out of room.
struct CompositionBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color

        init(_ id: String, _ value: Double, _ color: Color) {
            self.id = id
            self.value = value
            self.color = color
        }
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: width(for: segment, in: geometry.size.width))
                }
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private func width(for segment: Segment, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return max(0, min(available, available * segment.value / total))
    }
}

/// A legend entry on one line, for cards wide enough to hold label and value
/// side by side.
struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(.secondary)
                // Never wrap: a legend entry that becomes two lines breaks the
                // alignment of every row beside it.
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.callout)
    }
}

/// A legend entry stacked over two lines.
///
/// Side-by-side label and value need roughly twice the width, and in a
/// two-column legend inside a dashboard card there simply is not that much —
/// the label ends up truncated to "Compress…", which is worse than using the
/// second line.
struct LegendTile: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    /// Memory segment palette. Distinct in both appearances, and none of them
    /// red — memory being in use is normal, not an alarm.
    static let memoryApp = Color.accentColor
    static let memoryWired = Color.indigo
    static let memoryCompressed = Color.teal
    static let memoryCached = Color.secondary.opacity(0.45)
}

/// Per-core load as a row of vertical bars.
///
/// Eight stacked rows of text is a list; eight bars side by side is a shape the
/// eye reads in one glance, and it stays one line tall on a 24-core machine.
struct CoreBars: View {
    let usage: [Double]

    var body: some View {
        bars
            // Per-core load appears nowhere else in the app, so hiding this
            // outright removed the information rather than just the picture.
            // One element per core, because "core 3 is pinned while the rest
            // idle" is the whole point of the chart.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Per-core load")
            .accessibilityValue(summary)
    }

    private var summary: String {
        guard let busiest = usage.max(), let quietest = usage.min() else { return "No data" }
        return "\(usage.count) cores, busiest \(Format.percent(busiest)), quietest \(Format.percent(quietest))"
    }

    private var bars: some View {
        GeometryReader { geometry in
            let labelHeight: CGFloat = 13
            let barHeight = max(24, geometry.size.height - labelHeight - 5)
            // Columns share the width but are capped, so eight cores look like
            // a bar chart rather than eight fat blocks and twenty-four still fit
            // on one line.
            let spacing: CGFloat = 6
            let share = (geometry.size.width - spacing * CGFloat(max(0, usage.count - 1)))
                / CGFloat(max(1, usage.count))
            let columnWidth = max(8, min(44, share))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(usage.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 5) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.forUsage(value))
                                .frame(height: max(2, CGFloat(min(1, max(0, value))) * barHeight))
                        }
                        .frame(width: columnWidth, height: barHeight)

                        Text("\(index)")
                            .font(.axisLabel)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .frame(height: labelHeight)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Core \(index)")
                    .accessibilityValue(Format.percent(value))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Label and value on one line, sized for dense readouts inside a card.
struct InlineStat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .font(.note)
        // A stat that wraps mid-value ("304" above "Mbps") reads as two facts
        // rather than one.
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The headline number every card leads with.
struct CardValue: View {
    let value: String
    var caption: String?
    var size: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: size, weight: .medium, design: .rounded))
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One labelled figure. The building block every detail page is made of, so
/// all five pages read as the same product rather than five separate screens.
struct StatTile: View {
    let label: String
    let value: String
    var symbol: String?
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                Text(label)
                    .font(.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Text(value)
                .font(.tileValue)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card holding a grid of `StatTile`s.
struct TileCard: View {
    let title: String
    let symbol: String
    var columns: Int = 4
    let tiles: [StatTile]

    var body: some View {
        Card(title: title, symbol: symbol, fillsHeight: true) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading), count: columns),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    tile
                }
            }
        }
    }
}

/// The shared skeleton for a detail page: a hero at the top, a band of figures
/// under it, then whatever is specific to that subsystem. No page scrolls.
struct DetailPage<Hero: View, Figures: View, Extra: View>: View {
    let title: String
    var heroHeight: CGFloat = 180
    var figuresHeight: CGFloat = 96
    @ViewBuilder var hero: Hero
    @ViewBuilder var figures: Figures
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 12) {
            hero.frame(height: heroHeight)
            figures.frame(height: figuresHeight)
            extra.frame(maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }
}

/// A value with a copy button that appears on hover.
///
/// Addresses are things people paste into other places, and selecting small
/// monospaced text with the mouse is fiddly. The button confirms in place
/// rather than with an alert.
struct CopyableValue: View {
    let value: String
    var font: Font = .tileValue

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 5) {
            Text(value)
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                withAnimation(.easeOut(duration: 0.12)) { didCopy = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(.easeIn(duration: 0.2)) { didCopy = false }
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy \(value)")
            // Kept out of the way until wanted, but never re-laid out: the
            // button occupies its space whether or not it is visible.
            .opacity(isHovering || didCopy ? 1 : 0)
            .accessibilityLabel("Copy")
        }
        .onHover { isHovering = $0 }
    }
}

/// A `StatTile` whose value can be copied.
struct CopyableTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.note)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            CopyableValue(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card title that navigates. The chevron appears on hover so a card that
/// leads somewhere is discoverable without shouting about it.
private struct CardTitleLink: View {
    let title: String
    let symbol: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(isHovering ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.right")
                    .font(.note)
                    .foregroundStyle(.tertiary)
                    // Occupies its space whether or not it is visible, so the
                    // title does not shift under the pointer on hover.
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(title)")
        .layoutPriority(1)
    }
}

extension BatteryStats {
    /// The symbol that matches what the battery is doing, so the icon and the
    /// words never tell different stories.
    var symbolName: String {
        switch activity {
        case .charging: "battery.100.bolt"
        case .pluggedInNotCharging: "powerplug.fill"
        case .discharging:
            switch charge {
            case 0.75...: "battery.100"
            case 0.45..<0.75: "battery.75"
            case 0.20..<0.45: "battery.50"
            case 0.10..<0.20: "battery.25"
            default: "battery.0"
            }
        }
    }

    var symbolTint: Color {
        switch activity {
        case .charging: .green
        case .pluggedInNotCharging: .secondary
        case .discharging: charge < 0.20 ? .red : .secondary
        }
    }
}
