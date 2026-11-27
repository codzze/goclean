import AppKit
import GoCleanCore
import SwiftUI

/// Centralized formatting helpers using tabular numeric alignment.
public enum ByteFormatting {
    public static func string(from bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }

    public static func relativeDateString(from date: Date?) -> String {
        guard let date else { return "Unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// User-selectable color appearance mode.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case dark = "Dark"
    case light = "Light"
    case system = "Auto"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .dark: return "moon.stars.fill"
        case .light: return "sun.max.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    public var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}

/// Adaptive Native macOS Glass + Luminous Orbital Map color tokens.
public enum GoCleanTheme {
    public static let accentTeal = Color(red: 0.08, green: 0.76, blue: 0.80)
    public static let accentIndigo = Color(red: 0.42, green: 0.46, blue: 0.98)
    public static let accentCoral = Color(red: 0.96, green: 0.42, blue: 0.36)
    public static let accentAmber = Color(red: 0.96, green: 0.68, blue: 0.22)
    public static let accentEmerald = Color(red: 0.16, green: 0.80, blue: 0.56)
    public static let accentViolet = Color(red: 0.68, green: 0.42, blue: 0.98)
    public static let accentSky = Color(red: 0.22, green: 0.66, blue: 0.98)
    public static let accentDanger = Color(red: 0.96, green: 0.26, blue: 0.32)

    public static func color(for category: FileCategory) -> Color {
        switch category {
        case .applications: return accentIndigo
        case .media: return accentCoral
        case .developer: return accentTeal
        case .caches: return accentSky
        case .documents: return accentEmerald
        case .archives: return accentAmber
        case .system: return accentViolet
        case .other: return Color.secondary.opacity(0.75)
        }
    }

    /// Generates luminous harmonious ring colors by blending category hue with sibling index offset.
    public static func orbitalColor(for node: FileNode, ringDepth: Int, siblingIndex: Int) -> Color {
        let basePalette: [(h: Double, s: Double, b: Double)] = [
            (0.51, 0.76, 0.84), // Luminous Teal
            (0.64, 0.68, 0.90), // Electric Indigo
            (0.03, 0.72, 0.94), // Warm Coral
            (0.76, 0.62, 0.90), // Prism Violet
            (0.42, 0.72, 0.80), // Mint Emerald
            (0.10, 0.78, 0.94), // Amber Gold
            (0.57, 0.74, 0.92), // Cerulean Sky
            (0.92, 0.64, 0.90)  // Rose Quartz
        ]

        let catBase: (h: Double, s: Double, b: Double)
        switch node.dominantCategory {
        case .developer: catBase = (0.50, 0.78, 0.84)
        case .applications: catBase = (0.65, 0.68, 0.92)
        case .media: catBase = (0.03, 0.74, 0.94)
        case .caches: catBase = (0.56, 0.72, 0.92)
        case .documents: catBase = (0.43, 0.70, 0.82)
        case .archives: catBase = (0.10, 0.78, 0.94)
        case .system: catBase = (0.76, 0.60, 0.88)
        case .other:
            catBase = basePalette[siblingIndex % basePalette.count]
        }

        // Subtle shift across siblings and rings so adjacent arcs are always crisp and distinguishable
        let hueShift = Double(siblingIndex % 5) * 0.022 + Double(ringDepth) * 0.015
        let hue = (catBase.h + hueShift).truncatingRemainder(dividingBy: 1.0)
        let sat = max(0.38, catBase.s - Double(ringDepth) * 0.07)
        let bri = min(0.98, catBase.b + Double(ringDepth) * 0.03)
        return Color(hue: hue, saturation: sat, brightness: bri)
    }

    public static func color(for confidence: ConfidenceLevel) -> Color {
        switch confidence {
        case .high: return accentEmerald
        case .medium: return accentTeal
        case .review: return accentAmber
        case .danger: return accentDanger
        }
    }

    public static func icon(for confidence: ConfidenceLevel) -> String {
        switch confidence {
        case .high: return "checkmark.shield.fill"
        case .medium: return "shield.lefthalf.filled"
        case .review: return "eye.circle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        }
    }

    public static func color(for source: AppInstallSource) -> Color {
        switch source {
        case .appStore: return accentSky
        case .homebrewCask: return accentAmber
        case .homebrewFormula: return Color.orange
        case .directDownload: return accentIndigo
        case .curlCLI: return accentTeal
        }
    }

    public static func icon(for source: AppInstallSource) -> String {
        switch source {
        case .appStore: return "bag.fill"
        case .homebrewCask: return "mug.fill"
        case .homebrewFormula: return "terminal.fill"
        case .directDownload: return "arrow.down.app.fill"
        case .curlCLI: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Bespoke GoClean geometric brand emblem: a crystalline diamond prism swept by an
/// emerald-cyan clean blade and topped with crisp starlight sparkles (matching AppIcon.icns).
public struct GoCleanLogoMark: View {
    public let size: CGFloat

    public init(size: CGFloat = 44) {
        self.size = size
    }

    public var body: some View {
        Canvas { ctx, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let rect = CGRect(x: 0, y: 0, width: s, height: s)
            let bgPath = Path(roundedRect: rect, cornerRadius: s * 0.24, style: .continuous)

            // Deep midnight-sapphire to twilight-teal squircle tile
            ctx.fill(
                bgPath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.07, green: 0.14, blue: 0.28),
                        Color(red: 0.03, green: 0.07, blue: 0.15)
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: s, y: s)
                )
            )

            // Subtle ambient mint glow behind the prism
            let glowRect = CGRect(x: s * 0.12, y: s * 0.18, width: s * 0.76, height: s * 0.76)
            ctx.fill(
                Path(ellipseIn: glowRect),
                with: .radialGradient(
                    Gradient(colors: [
                        Color(red: 0.09, green: 0.82, blue: 0.74).opacity(0.28),
                        Color.clear
                    ]),
                    center: CGPoint(x: s * 0.50, y: s * 0.56),
                    startRadius: s * 0.05,
                    endRadius: s * 0.42
                )
            )

            // Upper frosted glass prism facet (angled architectural diamond plane)
            var upperFacet = Path()
            upperFacet.move(to: CGPoint(x: s * 0.48, y: s * 0.17))
            upperFacet.addLine(to: CGPoint(x: s * 0.74, y: s * 0.43))
            upperFacet.addLine(to: CGPoint(x: s * 0.46, y: s * 0.57))
            upperFacet.addLine(to: CGPoint(x: s * 0.20, y: s * 0.45))
            upperFacet.closeSubpath()

            ctx.fill(
                upperFacet,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.95),
                        Color(red: 0.74, green: 0.90, blue: 1.0).opacity(0.76)
                    ]),
                    startPoint: CGPoint(x: s * 0.25, y: s * 0.18),
                    endPoint: CGPoint(x: s * 0.72, y: s * 0.56)
                )
            )

            // Lower sweeping emerald-cyan ribbon blade cutting cleanly underneath
            var sweepBlade = Path()
            sweepBlade.move(to: CGPoint(x: s * 0.20, y: s * 0.50))
            sweepBlade.addQuadCurve(
                to: CGPoint(x: s * 0.78, y: s * 0.52),
                control: CGPoint(x: s * 0.48, y: s * 0.70)
            )
            sweepBlade.addLine(to: CGPoint(x: s * 0.50, y: s * 0.84))
            sweepBlade.addQuadCurve(
                to: CGPoint(x: s * 0.20, y: s * 0.50),
                control: CGPoint(x: s * 0.28, y: s * 0.72)
            )
            sweepBlade.closeSubpath()

            ctx.fill(
                sweepBlade,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.08, green: 0.88, blue: 0.72),
                        Color(red: 0.14, green: 0.58, blue: 0.98)
                    ]),
                    startPoint: CGPoint(x: s * 0.22, y: s * 0.52),
                    endPoint: CGPoint(x: s * 0.76, y: s * 0.82)
                )
            )

            // Crisp 4-point starlight sparkle at top-right
            func sparklePath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> Path {
                var p = Path()
                let inner = r * 0.26
                p.move(to: CGPoint(x: cx, y: cy - r))
                p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + inner, y: cy - inner))
                p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + inner, y: cy + inner))
                p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - inner, y: cy + inner))
                p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - inner, y: cy - inner))
                p.closeSubpath()
                return p
            }

            ctx.fill(sparklePath(cx: s * 0.76, cy: s * 0.24, r: s * 0.115), with: .color(.white))
            ctx.fill(sparklePath(cx: s * 0.84, cy: s * 0.36, r: s * 0.055), with: .color(Color(red: 0.42, green: 0.96, blue: 0.88)))

            // Subtle glass inner border
            let innerBorder = Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: s * 0.24, style: .continuous)
            ctx.stroke(innerBorder, with: .color(Color.white.opacity(0.18)), lineWidth: 1.2)
        }
        .frame(width: size, height: size)
        .shadow(color: GoCleanTheme.accentTeal.opacity(0.24), radius: 8, x: 0, y: 4)
    }
}

/// Reusable frosted glass card tuned for both rich Dark Mode and crisp Light Mode.
public struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let padding: CGFloat
    private let cornerRadius: CGFloat
    private let content: Content

    public init(padding: CGFloat = 16, cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                    if colorScheme == .dark {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.035))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.06),
                radius: colorScheme == .dark ? 14 : 10,
                x: 0,
                y: 4
            )
    }
}

/// Compact pill badge displaying cleanup safety status (Safe / Likely Safe / Review / Danger).
public struct ConfidenceBadge: View {
    public let level: ConfidenceLevel

    public var body: some View {
        let color = GoCleanTheme.color(for: level)
        HStack(spacing: 4) {
            Image(systemName: GoCleanTheme.icon(for: level))
                .font(.system(size: 10, weight: .bold))
            Text(level.rawValue)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(level == .danger ? 0.22 : 0.14), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(level == .danger ? 0.55 : 0.22), lineWidth: 0.8)
        )
        .foregroundStyle(color)
        .help(tooltipText)
    }

    private var tooltipText: String {
        switch level {
        case .high: return "Safe — No-impact file; safe to remove or automatically recreated."
        case .medium: return "Likely Safe — Usually safe to clean; confirm if still needed."
        case .review: return "Review — Personal or project data; inspect before removing."
        case .danger: return "Danger — System or protected OS file! Removing may break macOS or apps."
        }
    }
}

/// Compact pill badge displaying where an app was installed from.
public struct SourceBadge: View {
    public let source: AppInstallSource

    public var body: some View {
        let color = GoCleanTheme.color(for: source)
        Label(source.rawValue, systemImage: GoCleanTheme.icon(for: source))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Unified header banner for Smart Cleanup bucket screens.
public struct BucketHeaderView: View {
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let accentColor: Color
    public let totalBytes: UInt64
    public let itemCount: Int
    public let isLoading: Bool
    public let onScan: () -> Void
    public let extraActionTitle: String?
    public let onExtraAction: (() -> Void)?

    public init(
        title: String,
        subtitle: String,
        systemImage: String,
        accentColor: Color,
        totalBytes: UInt64,
        itemCount: Int,
        isLoading: Bool,
        onScan: @escaping () -> Void,
        extraActionTitle: String? = nil,
        onExtraAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accentColor = accentColor
        self.totalBytes = totalBytes
        self.itemCount = itemCount
        self.isLoading = isLoading
        self.onScan = onScan
        self.extraActionTitle = extraActionTitle
        self.onExtraAction = onExtraAction
    }

    public var body: some View {
        GlassCard(padding: 18, cornerRadius: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accentColor.gradient.opacity(0.22))
                        .frame(width: 50, height: 50)
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.bold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if itemCount > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteFormatting.string(from: totalBytes))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(accentColor)
                        Text("\(itemCount) \(itemCount == 1 ? "item" : "items") found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 6)
                }

                if let extraActionTitle, let onExtraAction, itemCount > 0 {
                    Button(extraActionTitle, action: onExtraAction)
                        .buttonStyle(.bordered)
                }

                Button(action: onScan) {
                    if isLoading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning…")
                        }
                    } else {
                        Label(itemCount > 0 ? "Rescan" : "Scan Now", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(isLoading)
            }
        }
    }
}

/// Friendly empty state shown before a bucket has been scanned or when disk is clean.
public struct EmptyBucketStateView: View {
    public let systemImage: String
    public let title: String
    public let description: String
    public let actionTitle: String
    public let accentColor: Color
    public let isLoading: Bool
    public let action: () -> Void

    public var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 82, height: 82)
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(accentColor)
                }
            }
            Text(isLoading ? "Analyzing your Mac…" : title)
                .font(.title3.weight(.semibold))
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !isLoading {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
