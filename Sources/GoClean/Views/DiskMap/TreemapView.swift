import GoCleanCore
import SwiftUI

/// Interactive Squarified Treemap view over the scanned `FileNode` subtree.
public struct TreemapView: View {
    public let rootNode: FileNode
    @Binding public var hoveredNodeID: UUID?
    @Binding public var selectedNodeID: UUID?
    public let onZoomIn: (FileNode) -> Void
    public let onStageNode: (FileNode) -> Void

    private struct TreemapTile: Identifiable {
        let id: UUID
        let node: FileNode
        let rect: CGRect
        let color: Color
    }

    public init(
        rootNode: FileNode,
        hoveredNodeID: Binding<UUID?>,
        selectedNodeID: Binding<UUID?>,
        onZoomIn: @escaping (FileNode) -> Void,
        onStageNode: @escaping (FileNode) -> Void
    ) {
        self.rootNode = rootNode
        self._hoveredNodeID = hoveredNodeID
        self._selectedNodeID = selectedNodeID
        self.onZoomIn = onZoomIn
        self.onStageNode = onStageNode
    }

    public var body: some View {
        GeometryReader { geo in
            let tiles = computeTiles(
                children: Array(rootNode.children.filter { $0.physicalSize > 0 }.prefix(48)),
                in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 8, dy: 8)
            )

            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    let isHovered = hoveredNodeID == tile.id
                    let isSelected = selectedNodeID == tile.id

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tile.color.gradient.opacity(isHovered ? 0.95 : 0.78))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isHovered || isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.18),
                                    lineWidth: isHovered ? 2 : 1
                                )
                        )
                        .overlay(alignment: .topLeading) {
                            if tile.rect.width > 74 && tile.rect.height > 42 {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tile.node.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(ByteFormatting.string(from: tile.node.physicalSize))
                                        .font(.caption2.weight(.medium).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.88))
                                }
                                .padding(8)
                            }
                        }
                        .frame(width: max(2, tile.rect.width - 4), height: max(2, tile.rect.height - 4))
                        .offset(x: tile.rect.minX + 2, y: tile.rect.minY + 2)
                        .onHover { hovering in
                            if hovering {
                                hoveredNodeID = tile.id
                            } else if hoveredNodeID == tile.id {
                                hoveredNodeID = nil
                            }
                        }
                        .onTapGesture {
                            if tile.node.isDirectory {
                                onZoomIn(tile.node)
                            } else {
                                selectedNodeID = tile.id
                            }
                        }
                        .contextMenu {
                            if tile.node.isDirectory {
                                Button("Zoom Into Folder") { onZoomIn(tile.node) }
                            }
                            Button("Stage in Collector") { onStageNode(tile.node) }
                            Button("Quick Look") { QuickLookController.shared.preview(url: tile.node.url) }
                            Button("Reveal in Finder") { QuickLookController.shared.revealInFinder(url: tile.node.url) }
                        }
                }
            }
        }
    }

    private func computeTiles(children: [FileNode], in bounds: CGRect) -> [TreemapTile] {
        guard !children.isEmpty, bounds.width > 8, bounds.height > 8 else { return [] }
        var tiles: [TreemapTile] = []
        var remainingRect = bounds
        var items = children
        var colorIdx = 0

        while !items.isEmpty && remainingRect.width > 4 && remainingRect.height > 4 {
            let totalRemaining = items.reduce(0.0) { $0 + Double($1.physicalSize) }
            guard totalRemaining > 0 else { break }

            let isHorizontalSplit = remainingRect.width >= remainingRect.height
            // Take a balanced strip of 1..4 items to preserve legible aspect ratios
            let stripCount = min(items.count, max(1, min(4, items.count / 3 + 1)))
            let strip = Array(items.prefix(stripCount))
            items.removeFirst(stripCount)

            let stripSum = strip.reduce(0.0) { $0 + Double($1.physicalSize) }
            let stripFraction = stripSum / totalRemaining

            if isHorizontalSplit {
                let stripWidth = remainingRect.width * stripFraction
                var y = remainingRect.minY
                for node in strip {
                    let h = remainingRect.height * (Double(node.physicalSize) / stripSum)
                    let rect = CGRect(x: remainingRect.minX, y: y, width: stripWidth, height: h)
                    tiles.append(TreemapTile(
                        id: node.id,
                        node: node,
                        rect: rect,
                        color: GoCleanTheme.orbitalColor(for: node, ringDepth: 0, siblingIndex: colorIdx)
                    ))
                    colorIdx += 1
                    y += h
                }
                remainingRect = CGRect(
                    x: remainingRect.minX + stripWidth,
                    y: remainingRect.minY,
                    width: remainingRect.width - stripWidth,
                    height: remainingRect.height
                )
            } else {
                let stripHeight = remainingRect.height * stripFraction
                var x = remainingRect.minX
                for node in strip {
                    let w = remainingRect.width * (Double(node.physicalSize) / stripSum)
                    let rect = CGRect(x: x, y: remainingRect.minY, width: w, height: stripHeight)
                    tiles.append(TreemapTile(
                        id: node.id,
                        node: node,
                        rect: rect,
                        color: GoCleanTheme.orbitalColor(for: node, ringDepth: 0, siblingIndex: colorIdx)
                    ))
                    colorIdx += 1
                    x += w
                }
                remainingRect = CGRect(
                    x: remainingRect.minX,
                    y: remainingRect.minY + stripHeight,
                    width: remainingRect.width,
                    height: remainingRect.height - stripHeight
                )
            }
        }

        return tiles
    }
}
