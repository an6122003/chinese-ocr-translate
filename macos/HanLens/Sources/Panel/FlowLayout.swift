import SwiftUI

/// Marks a subview as a forced line break inside ``FlowLayout``.
nonisolated struct FlowLineBreak: LayoutValueKey {
    static let defaultValue = false
}

/// Lays subviews out left to right, wrapping onto new rows — like text.
nonisolated struct FlowLayout: Layout {
    var spacing: CGFloat = 2
    var rowSpacing: CGFloat = 8

    struct Placement {
        var index: Int
        var origin: CGPoint
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (_, size) = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (placements, _) = arrange(width: bounds.width, subviews: subviews)
        for placement in placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size))
        }
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> ([Placement], CGSize) {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        var rowHasItems = false

        func newRow(minimumHeight: CGFloat = 0) {
            y += max(rowHeight, minimumHeight) + rowSpacing
            x = 0
            rowHeight = 0
            rowHasItems = false
        }

        for index in subviews.indices {
            if subviews[index][FlowLineBreak.self] {
                // An empty line still takes up the height of a (short) row.
                newRow(minimumHeight: rowHasItems ? 0 : 12)
                continue
            }
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            if rowHasItems, x + size.width > maxWidth {
                newRow()
            }
            placements.append(Placement(index: index, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
            rowHasItems = true
        }
        let height = rowHasItems ? y + rowHeight : max(0, y - rowSpacing)
        return (placements, CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: height))
    }
}
