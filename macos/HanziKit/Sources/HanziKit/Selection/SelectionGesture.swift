import CoreGraphics

/// Interprets a drag (mouse, trackpad, finger or Pencil) either as a rectangle (corner to corner) or as a
/// free-form lasso ("circle to search"): circling or scribbling over text strays far from the start→end line.
public struct SelectionGesture: Sendable {
    public enum Shape: Equatable, Sendable { case rectangle, lasso }

    public private(set) var points: [CGPoint] = []
    public private(set) var shape: Shape = .rectangle
    private var pathLength: CGFloat = 0

    public init(start: CGPoint) {
        points = [start]
    }

    public var start: CGPoint { points[0] }
    public var end: CGPoint { points[points.count - 1] }

    public mutating func add(_ point: CGPoint) {
        guard let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1.5 else { return }
        pathLength += hypot(point.x - last.x, point.y - last.y)
        points.append(point)
        // Once a lasso, always a lasso — avoids flicker while circling back towards the start.
        if shape == .rectangle, Self.looksLikeLasso(points: points, pathLength: pathLength) {
            shape = .lasso
        }
    }

    /// Travelled distance (to tell a click from a drag).
    public var travelled: CGFloat { pathLength }

    static func looksLikeLasso(points: [CGPoint], pathLength: CGFloat) -> Bool {
        guard points.count > 8, let start = points.first, let end = points.last else { return false }
        let chord = hypot(end.x - start.x, end.y - start.y)
        // A rectangle drag travels roughly in a straight line; a circle travels much further than its chord.
        guard pathLength > 2.2 * max(chord, 1) else { return false }
        return maxDeviation(of: points, from: start, to: end) > 24
    }

    /// Largest perpendicular distance from the start→end line (or from the start when they coincide).
    static func maxDeviation(of points: [CGPoint], from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        return points.reduce(0) { result, p in
            let distance = length < 1
                ? hypot(p.x - a.x, p.y - a.y)
                : abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
            return max(result, distance)
        }
    }

    /// The rectangle being selected (rectangle mode) or the lasso's bounding box.
    public var rect: CGRect {
        switch shape {
        case .rectangle:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        case .lasso:
            return lassoPath.boundingBoxOfPath
        }
    }

    /// Closed, smoothed lasso outline.
    public var lassoPath: CGPath {
        let path = CGMutablePath()
        guard points.count > 2 else {
            path.addRect(CGRect(origin: start, size: .zero))
            return path
        }
        path.move(to: points[0])
        // Quadratic smoothing through midpoints.
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        path.closeSubpath()
        return path
    }

    /// The outline to draw for the current shape.
    public var outline: CGPath {
        switch shape {
        case .rectangle: CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        case .lasso: lassoPath
        }
    }
}
