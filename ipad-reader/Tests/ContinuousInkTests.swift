import XCTest
import PencilKit
@testable import YeJian

final class ContinuousInkTests: XCTestCase {
    private func stroke(from start: CGFloat, to end: CGFloat) -> PKStroke {
        let points = [start, (start + end) / 2, end].enumerated().map { index, x in
            PKStrokePoint(location: CGPoint(x: x, y: 200), timeOffset: Double(index) * 0.05,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
    func testCrossingStrokeSurvivesBackupAndPortraitTranslation() throws {
        let original = PKDrawing(strokes: [stroke(from: 480, to: 740)])
        var state = BookReadingState()
        state.layout.width = 590
        state.spreadDrawings[ReaderInk.key(left: "left", right: "right")] = original.dataRepresentation()
        let restored = try JSONDecoder().decode(BookReadingState.self, from: JSONEncoder().encode(state))
        let spread = ReaderInk.drawing(state: restored, left: "left", right: "right", width: 590)
        XCTAssertEqual(spread.strokes.count, 1)
        XCTAssertEqual(spread.strokes[0].path.count, 3)
        XCTAssertEqual(spread.strokes[0].path[2].location.x, 740, accuracy: 0.001)
        let portrait = spread.transformed(using: CGAffineTransform(translationX: -590, y: 0))
        XCTAssertEqual(portrait.strokes.count, 1)
        // PKStroke transforms preserve control points; the transform carries the
        // leaf offset, so a cross-page stroke remains one vector stroke.
        XCTAssertEqual(portrait.strokes[0].transform.tx, -590, accuracy: 0.001)
    }
    func testLegacyRightLeafMovesIntoSharedCanvasAndEmptyCanonicalWins() {
        var state = BookReadingState()
        state.drawings["left"] = PKDrawing(strokes: [stroke(from: 100, to: 180)]).dataRepresentation()
        state.drawings["right"] = PKDrawing(strokes: [stroke(from: 10, to: 80)]).dataRepresentation()
        let migrated = ReaderInk.drawing(state: state, left: "left", right: "right", width: 680)
        XCTAssertEqual(migrated.strokes.count, 2)
        XCTAssertEqual(migrated.strokes[1].transform.tx, 680, accuracy: 0.001)
        state.spreadDrawings[ReaderInk.key(left: "left", right: "right")] = PKDrawing().dataRepresentation()
        XCTAssertTrue(ReaderInk.drawing(state: state, left: "left", right: "right", width: 680).strokes.isEmpty)
    }
}
