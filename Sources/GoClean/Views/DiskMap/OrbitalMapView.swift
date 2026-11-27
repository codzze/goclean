import GoCleanCore
import SwiftUI

/// Bespoke concentric radial disk visualization: the **Luminous Orbital Map**.
/// Renders up to 4 concentric rings of files & folders sized strictly proportional
/// to APFS physical disk bytes, with polar hit-testing, hover glow, central glass hub,
/// and smooth drill-down navigation.
public struct OrbitalMapView: View {
    public let rootNode: FileNode
    @Binding public var hoveredNodeID: UUID?
    @Binding public var selectedNodeID: UUID?
    public let canZoomOut: Bool
    public let onZoomIn: (FileNode) -> Void
    public let onZoomOut: () -> Void
    public let onStageNode: (FileNode) -> Void

    @State private var hoverLocation: CGPoint?
    @State private var computedArcs: [OrbitalArc] = []

    private struct OrbitalArc: Identifiable {
        let id: UUID
        let node: FileNode?
        let isOtherBucket: Bool
        let otherCount: Int
        let displayName: String
        let byteSize: UInt64
        let ringDepth: Int
        let startAngle: Double // radians, 0 at top (-pi/2 offset applied on draw)
        let endAngle: Double
        let innerRatio: Double
        let outerRatio: Double
        let color: Color
    }

    public init(
        rootNode: FileNode,
        hoveredNodeID: Binding<UUID?>,
        selectedNodeID: Binding<UUID?>,
        canZoomOut: Bool,
        onZoomIn: @escaping (FileNode) -> Void,
        onZoomOut: @escaping () -> Void,
        onStageNode: @escaping (FileNode) -> Void
    ) {
        self.rootNode = rootNode
        self._hoveredNodeID = hoveredNodeID
        self._selectedNodeID = selectedNodeID
        self.canZoomOut = canZoomOut
        self.onZoomIn = onZoomIn
        self.onZoomOut = onZoomOut
        self.onStageNode = onStageNode
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxRadius = max(60, (side * 0.46))
            let hubRadius = maxRadius * 0.30
            let arcs = buildArcs(for: rootNode)
            let hoveredArc = arcs.first { $0.node?.id == hoveredNodeID }

            ZStack {
                // Subtle ambient orbital backdrop rings
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let maxR = max(60, min(size.width, size.height) * 0.46)

                    // Faint guide orbits
                    for ratio in [0.30, 0.48, 0.66, 0.83, 1.0] {
                        let r = maxR * ratio
                        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                        ctx.stroke(
                            Path(ellipseIn: rect),
                            with: .color(Color.primary.opacity(0.045)),
                            lineWidth: 1
                        )
                    }

                    // Draw arcs back-to-front (outer to inner or standard)
                    for arc in arcs {
                        let isHovered = arc.node != nil && arc.node?.id == hoveredNodeID
                        let isSelected = arc.node != nil && arc.node?.id == selectedNodeID
                        let expansion: Double = isHovered ? 6.0 : (isSelected ? 3.5 : 0.0)
                        let rInner = maxR * arc.innerRatio + 1.5
                        let rOuter = maxR * arc.outerRatio - 1.5 + expansion

                        let angularGap = min(0.012, (arc.endAngle - arc.startAngle) * 0.08)
                        let startRad = arc.startAngle - .pi / 2 + angularGap / 2
                        let endRad = arc.endAngle - .pi / 2 - angularGap / 2
                        guard endRad > startRad else { continue }

                        var path = Path()
                        path.addArc(
                            center: c,
                            radius: rOuter,
                            startAngle: .radians(startRad),
                            endAngle: .radians(endRad),
                            clockwise: false
                        )
                        path.addArc(
                            center: c,
                            radius: rInner,
                            startAngle: .radians(endRad),
                            endAngle: .radians(startRad),
                            clockwise: true
                        )
                        path.closeSubpath()

                        let baseOpacity: Double = arc.isOtherBucket
                            ? 0.28
                            : (hoveredNodeID == nil || isHovered || isSelected ? 0.92 : 0.58)

                        // Luminous glow on hovered slice
                        if isHovered {
                            ctx.drawLayer { layer in
                                layer.addFilter(.shadow(color: arc.color.opacity(0.65), radius: 14, x: 0, y: 0))
                                layer.fill(path, with: .color(arc.color))
                            }
                        }

                        // Subtle radial sheen gradient inside each arc
                        let grad = Gradient(colors: [
                            arc.color.opacity(baseOpacity * 0.85),
                            arc.color.opacity(baseOpacity)
                        ])
                        ctx.fill(
                            path,
                            with: .radialGradient(
                                grad,
                                center: c,
                                startRadius: rInner,
                                endRadius: rOuter
                            )
                        )

                        ctx.stroke(
                            path,
                            with: .color(isHovered ? Color.white.opacity(0.85) : Color.white.opacity(0.18)),
                            lineWidth: isHovered ? 1.8 : 0.7
                        )
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverLocation = point
                        if let hit = hitTest(point: point, center: center, maxRadius: maxRadius, arcs: arcs) {
                            hoveredNodeID = hit.node?.id
                        } else {
                            hoveredNodeID = nil
                        }
                    case .ended:
                        hoverLocation = nil
                        hoveredNodeID = nil
                    }
                }
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            let point = value.location
                            let dx = point.x - center.x
                            let dy = point.y - center.y
                            let dist = hypot(dx, dy)
                            if dist <= hubRadius {
                                if canZoomOut { onZoomOut() }
                                return
                            }
                            if let hit = hitTest(point: point, center: center, maxRadius: maxRadius, arcs: arcs),
                               let node = hit.node {
                                if node.isDirectory {
                                    onZoomIn(node)
                                } else {
                                    selectedNodeID = node.id
                                }
                            }
                        }
                )

                // Central Frosted Glass Hub
                centralHub(hubRadius: hubRadius, hoveredArc: hoveredArc)

                // Floating Telemetry Pill when hovering an arc
                if let hoveredArc, let hoveredNode = hoveredArc.node {
                    VStack {
                        Spacer()
                        hoverTelemetryPill(arc: hoveredArc, node: hoveredNode)
                            .padding(.bottom, 12)
                    }
                    .allowsHitTesting(true)
                }
            }
        }
    }

    // MARK: - Central Glass Hub

    private func centralHub(hubRadius: CGFloat, hoveredArc: OrbitalArc?) -> some View {
        let displayTitle = hoveredArc?.displayName ?? rootNode.name
        let displaySize = hoveredArc?.byteSize ?? rootNode.physicalSize
        let sharePct: String? = {
            guard let hoveredArc, rootNode.physicalSize > 0 else { return nil }
            let pct = (Double(hoveredArc.byteSize) / Double(rootNode.physicalSize)) * 100.0
            return String(format: "%.1f%%", pct)
        }()

        return Button {
            if canZoomOut { onZoomOut() }
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.14), radius: 16, x: 0, y: 6)
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                (hoveredArc?.color ?? GoCleanTheme.accentTeal).opacity(0.65),
                                Color.primary.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )

                VStack(spacing: 4) {
                    if canZoomOut && hoveredArc == nil {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.caption)
                            .foregroundStyle(GoCleanTheme.accentTeal)
                    }

                    Text(ByteFormatting.string(from: displaySize))
                        .font(.system(size: max(15, hubRadius * 0.25), weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(displayTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)

                    if let sharePct {
                        Text(sharePct)
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(hoveredArc?.color ?? GoCleanTheme.accentTeal)
                    } else {
                        Text("\(rootNode.fileCount.formatted()) items")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
            }
            .frame(width: hubRadius * 1.92, height: hubRadius * 1.92)
        }
        .buttonStyle(.plain)
        .help(canZoomOut ? "Click center hub to zoom out to parent folder" : rootNode.url.path)
    }

    // MARK: - Hover Telemetry HUD

    private func hoverTelemetryPill(arc: OrbitalArc, node: FileNode) -> some View {
        GlassCard(padding: 10, cornerRadius: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(arc.color)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(node.url.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 320, alignment: .leading)
                }

                Divider().frame(height: 24)

                Text(ByteFormatting.string(from: node.physicalSize))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(arc.color)

                Button {
                    onStageNode(node)
                } label: {
                    Label("Collect", systemImage: "tray.and.arrow.down.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(arc.color)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Radial Layout & Polar Hit Testing

    private func buildArcs(for root: FileNode) -> [OrbitalArc] {
        let totalBytes = root.physicalSize
        guard totalBytes > 0 else { return [] }

        var arcs: [OrbitalArc] = []
        let ringBounds: [(inner: Double, outer: Double)] = [
            (0.31, 0.49),
            (0.50, 0.67),
            (0.68, 0.84),
            (0.85, 0.99)
        ]

        func layoutChildren(
            of parent: FileNode,
            depth: Int,
            startAngle: Double,
            endAngle: Double
        ) {
            guard depth < ringBounds.count else { return }
            let parentBytes = parent.physicalSize
            let span = endAngle - startAngle
            guard parentBytes > 0, span > 0.03 else { return }

            let bounds = ringBounds[depth]
            let minRenderAngle = depth == 0 ? 0.030 : 0.042 // ~1.7 deg outer culling

            var cursor = startAngle
            var otherBytes: UInt64 = 0
            var otherCount = 0

            for (idx, child) in parent.children.enumerated() {
                guard child.physicalSize > 0 else { continue }
                let fraction = Double(child.physicalSize) / Double(parentBytes)
                let sliceAngle = span * fraction

                if sliceAngle < minRenderAngle {
                    otherBytes &+= child.physicalSize
                    otherCount += 1
                    continue
                }

                let sliceEnd = min(endAngle, cursor + sliceAngle)
                let color = GoCleanTheme.orbitalColor(for: child, ringDepth: depth, siblingIndex: idx)

                arcs.append(OrbitalArc(
                    id: child.id,
                    node: child,
                    isOtherBucket: false,
                    otherCount: 0,
                    displayName: child.name,
                    byteSize: child.physicalSize,
                    ringDepth: depth,
                    startAngle: cursor,
                    endAngle: sliceEnd,
                    innerRatio: bounds.inner,
                    outerRatio: bounds.outer,
                    color: color
                ))

                if child.isDirectory && !child.children.isEmpty && sliceAngle > 0.09 {
                    layoutChildren(
                        of: child,
                        depth: depth + 1,
                        startAngle: cursor,
                        endAngle: sliceEnd
                    )
                }

                cursor = sliceEnd
            }

            if otherBytes > 0 && endAngle - cursor > 0.025 {
                arcs.append(OrbitalArc(
                    id: UUID(),
                    node: nil,
                    isOtherBucket: true,
                    otherCount: otherCount,
                    displayName: "\(otherCount) smaller items",
                    byteSize: otherBytes,
                    ringDepth: depth,
                    startAngle: cursor,
                    endAngle: endAngle,
                    innerRatio: bounds.inner,
                    outerRatio: bounds.outer,
                    color: Color.secondary
                ))
            }
        }

        layoutChildren(of: root, depth: 0, startAngle: 0, endAngle: .pi * 2)
        return arcs
    }

    private func hitTest(
        point: CGPoint,
        center: CGPoint,
        maxRadius: CGFloat,
        arcs: [OrbitalArc]
    ) -> OrbitalArc? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = hypot(dx, dy)
        let ratio = Double(dist / maxRadius)
        guard ratio >= 0.30 && ratio <= 1.04 else { return nil }

        // Angle measured clockwise from 12 o'clock (0 ..< 2pi)
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += .pi * 2 }

        for arc in arcs {
            if ratio >= arc.innerRatio && ratio <= arc.outerRatio &&
                angle >= arc.startAngle && angle <= arc.endAngle {
                return arc
            }
        }
        return nil
    }
}
