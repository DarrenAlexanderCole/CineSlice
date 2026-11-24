import PDFKit
import XCTest

@testable import PocketInstrument

final class HelpManualTests: XCTestCase {
    /// The manual is the help cards' own text: every topic, under its page, then the credits.
    @MainActor
    func testManualCoversEveryTopicAndWritesAPDF() throws {
        let text = HelpManual.text().string
        for topic in HelpTopic.allCases {
            XCTAssertTrue(text.contains(topic.title + "\n" + topic.body), topic.rawValue)
        }
        XCTAssertTrue(text.contains("DBS-TIGER"))

        let url = try HelpManual.write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("manual-test.pdf"))
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(pdf.pageCount, 3)
        XCTAssertLessThan(pdf.pageCount, 20)
        let printed = try XCTUnwrap(pdf.string)
        XCTAssertTrue(printed.contains("Jog wheel"))
        XCTAssertTrue(printed.contains("CineSlice Manual · \(pdf.pageCount)"), "last page is numbered")
    }
}
