import UIKit

/// The CineSlice manual as a PDF, made on the device from the help cards' own text (`HelpTopic`),
/// so it always matches the installed version: an introduction, each page's controls, then credits.
enum HelpManual {
    static let creator = "Darren Alexander Cole"
    /// The development team, as each asked to be named. Shown after the creator in the credits.
    static let developmentTeam = ["Maya Anderson", "Jerrold Goodman", "Ashley Ferrara", "Kate Mytty"]

    static let repository = "github.com/DarrenAlexanderCole/CineSlice"

    /// The PDF in the temporary folder, made once per launch on first use; nil if it couldn't be written.
    @MainActor static let url: URL? = try? write(
        to: FileManager.default.temporaryDirectory.appendingPathComponent("CineSlice Manual.pdf"))

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// US Letter, with inch margins at the sides and room for the page number.
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let body = CGRect(x: 72, y: 64, width: 468, height: 664)

    @discardableResult
    static func write(to url: URL) throws -> URL {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "CineSlice Manual",
            kCGPDFContextAuthor as String: "CineSlice",
        ]
        try UIGraphicsPDFRenderer(bounds: page, format: format).writePDF(to: url) { context in
            var y = body.minY
            var number = 0
            func newPage() {
                context.beginPage()
                number += 1
                NSAttributedString(string: "CineSlice Manual · \(number)", attributes: style(.footer))
                    .draw(at: CGPoint(x: body.minX, y: page.height - 44))
                y = body.minY
            }
            newPage()
            // A block never splits, so a heading stays with its text; one that doesn't fit starts a page.
            for block in blocks() {
                let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
                let height = ceil(
                    block.text.boundingRect(
                        with: CGSize(width: body.width, height: .greatestFiniteMagnitude), options: options,
                        context: nil
                    ).height)
                if y > body.minY { y += block.gap }
                if y + height > body.maxY, y > body.minY { newPage() }
                block.text.draw(
                    with: CGRect(x: body.minX, y: y, width: body.width, height: height), options: options,
                    context: nil)
                y += height
            }
        }
        return url
    }

    // MARK: Text

    private enum Style { case title, subtitle, heading, intro, topic, body, footer }

    private static let olive = UIColor(red: 0x56 / 255, green: 0x62 / 255, blue: 0x3B / 255, alpha: 1)
    private static let ink = UIColor(red: 0x15 / 255, green: 0x18 / 255, blue: 0x16 / 255, alpha: 1)
    private static let grey = UIColor(red: 0x55 / 255, green: 0x58 / 255, blue: 0x50 / 255, alpha: 1)

    private static func style(_ style: Style) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        let font: UIFont
        var color = ink
        switch style {
        case .title:
            font = .systemFont(ofSize: 30, weight: .bold)
            paragraph.paragraphSpacing = 4
        case .subtitle:
            font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            color = grey
            paragraph.paragraphSpacing = 18
        case .heading:
            font = .systemFont(ofSize: 20, weight: .bold)
            color = olive
            paragraph.paragraphSpacing = 4
        case .intro:
            font = .italicSystemFont(ofSize: 12)
            color = grey
            paragraph.paragraphSpacing = 10
        case .topic:
            font = .systemFont(ofSize: 12, weight: .semibold)
            paragraph.paragraphSpacing = 1
        case .body:
            font = .systemFont(ofSize: 11)
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 4
        case .footer:
            font = .monospacedSystemFont(ofSize: 8, weight: .regular)
            color = grey
        }
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// The manual's text in one piece.
    static func text() -> NSAttributedString {
        let text = NSMutableAttributedString()
        for block in blocks() {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(block.text)
        }
        return text
    }

    /// The manual in pieces that stay together on a page, each with the space above it.
    private static func blocks() -> [(text: NSAttributedString, gap: CGFloat)] {
        var blocks: [(text: NSMutableAttributedString, gap: CGFloat)] = []
        /// Starts a new block.
        func next(gap: CGFloat) { blocks.append((NSMutableAttributedString(), gap)) }
        func add(_ string: String, _ s: Style) {
            if blocks.isEmpty { next(gap: 0) }
            let block = blocks[blocks.count - 1].text
            block.append(NSAttributedString(string: (block.length > 0 ? "\n" : "") + string, attributes: style(s)))
        }

        add("CineSlice Manual", .title)
        add("VERSION \(version) · \(repository.uppercased())", .subtitle)
        next(gap: 14)
        add("How CineSlice works", .heading)
        add(
            "CineSlice is an editing instrument: the picture fills the screen and the controls are keys, faders "
                + "and a wheel you play while your footage runs. Watching your own footage is how the best edits "
                + "are made, so playback keeps going while you work, and Watch shows nothing but the picture.",
            .body)
        add(
            "One edit has four pages: Arrange lines up the clips, Trim picks the part of each clip you use, Mix "
                + "lines music up and balances levels, and Audio splits voices and shapes the sound. Release makes "
                + "the video. Move between them in any order. Nothing ever changes your original footage, and "
                + "undo steps back through every edit.",
            .body)
        add(
            "Not sure what something does? Tap the ? key at the top. While help is on, tapping any control "
                + "explains it instead of using it. This manual is the same help, page by page.",
            .body)

        for page in HelpPage.allCases {
            next(gap: 26)
            add(page.title, .heading)
            add(page.intro, .intro)
            // The page's title and introduction stay with its first control.
            for (index, topic) in HelpTopic.allCases.filter({ $0.page == page }).enumerated() {
                if index > 0 { next(gap: 8) }
                add(topic.title, .topic)
                add(topic.body, .body)
            }
        }

        next(gap: 26)
        add("Credits", .heading)
        add("Creator and Lead Developer", .topic)
        add(creator, .body)
        if !developmentTeam.isEmpty {
            next(gap: 8)
            add("Development Team", .topic)
            add(developmentTeam.joined(separator: "\n"), .body)
        }
        next(gap: 8)
        add("Voice split", .topic)
        add(
            "Voice separation uses DBS-TIGER-DnR (github.com/JusperLee/Dynamic-Band-Splitting, Tsinghua "
                + "University), converted to Core ML, under the Apache License 2.0 "
                + "(apache.org/licenses/LICENSE-2.0).",
            .body)
        next(gap: 8)
        add("Source", .topic)
        add("CineSlice's source code is at \(repository).", .body)
        return blocks.map { ($0.text, $0.gap) }
    }
}
