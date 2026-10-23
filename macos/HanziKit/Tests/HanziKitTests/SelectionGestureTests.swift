import CoreGraphics
import Foundation
import Testing
@testable import HanziKit

@Suite("Selection gesture")
struct SelectionGestureTests {
    private func gesture(_ points: [CGPoint]) -> SelectionGesture {
        var gesture = SelectionGesture(start: points[0])
        for point in points.dropFirst() { gesture.add(point) }
        return gesture
    }

    @Test func straightDragIsARectangle() {
        let points = stride(from: 0.0, through: 1.0, by: 0.02).map { CGPoint(x: 100 + 300 * $0, y: 200 + 80 * $0) }
        let result = gesture(points)
        #expect(result.shape == .rectangle)
        #expect(result.rect == CGRect(x: 100, y: 200, width: 300, height: 80))
    }

    @Test func wobblyDragIsStillARectangle() {
        let points = stride(from: 0.0, through: 1.0, by: 0.02).map { (t: Double) -> CGPoint in
            let x: Double = 100 + 300 * t + 3 * sin(t * 40)
            let y: Double = 200 + 80 * t + 3 * cos(t * 37)
            return CGPoint(x: x, y: y)
        }
        #expect(gesture(points).shape == .rectangle)
    }

    @Test func circleIsALasso() {
        let points = stride(from: 0.0, through: 2 * Double.pi, by: 0.08).map {
            CGPoint(x: 400 + 150 * cos($0), y: 300 + 60 * sin($0))
        }
        let result = gesture(points)
        #expect(result.shape == .lasso)
        // The lasso's box covers the circled area.
        #expect(result.rect.insetBy(dx: -4, dy: -4).contains(CGRect(x: 260, y: 250, width: 280, height: 100)))
        #expect(result.lassoPath.contains(CGPoint(x: 400, y: 300)))
        #expect(!result.lassoPath.contains(CGPoint(x: 600, y: 300)))
    }

    @Test func scribbleIsALasso() {
        // Back-and-forth zigzag over a word.
        let points = stride(from: 0.0, through: 1.0, by: 0.01).map { t in
            CGPoint(x: 100 + 200 * t, y: 100 + 40 * sin(t * 30))
        }
        #expect(gesture(points).shape == .lasso)
    }

    @Test func clickHasNoTravel() {
        let result = gesture([CGPoint(x: 10, y: 10), CGPoint(x: 10.5, y: 10.4)])
        #expect(result.travelled < 5)
    }
}
