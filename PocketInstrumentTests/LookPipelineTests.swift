import AVFoundation
import CoreImage
import EditCore
import XCTest

@testable import PocketInstrument

/// Looks through the real pipeline: the compositor that draws them must frame the picture
/// exactly as the system's does, only coloured.
@MainActor
final class LookPipelineTests: XCTestCase {
    private var store: ProjectStore!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try ProjectStore(rootURL: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A small grey picture of the composition at `seconds`, with its average colourfulness.
    private func frame(of project: Project, at seconds: Double) async throws -> (luma: [Double], chroma: Double) {
        let built = try await CompositionBuilder.build(
            project: project, renderSize: CGSize(width: 360, height: 640), frameRate: 30, includeClipAudio: false,
            includeMusic: false, mediaURL: { self.store.mediaURL(for: $0, projectID: project.id) }, musicURL: nil)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let width = 36
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var luma: [Double] = []
        var chroma = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
            luma.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            chroma += max(r, g, b) - min(r, g, b)
        }
        return (luma, chroma / Double(luma.count))
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0
        var da = 0.0
        var db = 0.0
        for (x, y) in zip(a, b) {
            num += (x - ma) * (y - mb)
            da += (x - ma) * (x - ma)
            db += (y - mb) * (y - mb)
        }
        return num / max(1e-9, (da * db).squareRoot())
    }

    func testALookColoursThePictureButFramesItTheSame() async throws {
        var project = try store.create(name: "Looks")
        let sources = try await DemoMediaGenerator.makeDemoSources(store: store, projectID: project.id)
        try AddClipsCommand(sources: sources).apply(to: &project)
        let plain = try await frame(of: project, at: 1)

        let noir = try XCTUnwrap(LookLibrary.builtIns.first { $0.id == "builtin:noir" })
        try SetSourceLookCommand(sourceID: sources[0].id, look: noir).apply(to: &project)
        let graded = try await frame(of: project, at: 1)

        XCTAssertGreaterThan(plain.chroma, 20, "the demo clip should be colourful")
        XCTAssertLessThan(graded.chroma, 6, "NOIR should take the colour out")
        // Same picture in the same place: not flipped, moved or scaled by the compositor.
        XCTAssertGreaterThan(correlation(plain.luma, graded.luma), 0.85)
        // …which this check would catch: the same frame upside down doesn't pass it.
        let flipped = stride(from: 63, through: 0, by: -1).flatMap { row in plain.luma[(row * 36)..<(row * 36 + 36)] }
        XCTAssertLessThan(correlation(plain.luma, flipped), 0.85)

        // The clip after it has no look and plays as it always did.
        let second = try await frame(of: project, at: 7)
        XCTAssertGreaterThan(second.chroma, 20)
    }

    func testCubeFilesAreReadAndBadOnesRefused() throws {
        let identity = """
            TITLE "Identity"
            # a comment
            LUT_3D_SIZE 2
            DOMAIN_MIN 0 0 0
            DOMAIN_MAX 1 1 1
            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """
        let cube = try LookLibrary.parseCube(identity)
        XCTAssertEqual(cube.size, 2)
        XCTAssertEqual(cube.data.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
        XCTAssertThrowsError(try LookLibrary.parseCube("LUT_1D_SIZE 2\n0 0 0\n1 1 1"))
        XCTAssertThrowsError(try LookLibrary.parseCube("LUT_3D_SIZE 2\n0 0 0\n1 1 1"))
        // Every built-in look draws a full table.
        for look in LookLibrary.builtIns {
            XCTAssertEqual(LookLibrary.cube(for: look)?.data.count, 33 * 33 * 33 * 4 * MemoryLayout<Float>.size)
        }
    }

    /// The colour at table point (r, g, b) of a look's LUT.
    private func entry(_ cube: LookCube, _ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
        cube.data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            let i = ((b * cube.size + g) * cube.size + r) * 4
            return SIMD3(values[i], values[i + 1], values[i + 2])
        }
    }

    func testFilmLooksKeepTheirTonesInOrder() throws {
        // Every look shows the menu's sections, and the original six keep their ids.
        let grouped = LookLibrary.builtInGroups.flatMap(\.looks).map(\.id)
        XCTAssertEqual(Set(grouped), Set(LookLibrary.builtIns.map(\.id)))
        for id in ["koda", "blockbuster", "bleach", "noir", "seventies", "night"] {
            XCTAssertTrue(grouped.contains("builtin:\(id)"))
        }
        for look in LookLibrary.builtIns {
            let cube = try XCTUnwrap(LookLibrary.cube(for: look))
            // A brighter grey never prints darker: no look folds its tones over.
            var last: Float = -1
            for i in 0..<cube.size {
                let c = entry(cube, i, i, i)
                let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                XCTAssertGreaterThanOrEqual(luma, last - 0.002, "\(look.name) at grey \(i)")
                last = luma
            }
        }
        // The black-and-white looks leave no colour on a saturated picture (sepia is toned).
        let mono = try XCTUnwrap(LookLibrary.builtInGroups.first { $0.title == "Black & white" }).looks
        for look in mono where look.name != "SEPIA" {
            let cube = try XCTUnwrap(LookLibrary.cube(for: look))
            for (r, g, b) in [(32, 0, 0), (0, 32, 0), (0, 0, 32), (32, 20, 4)] {
                let c = entry(cube, r, g, b)
                XCTAssertLessThan(max(c.x, c.y, c.z) - min(c.x, c.y, c.z), 0.002, look.name)
            }
        }
        // Through the red filter a blue sky prints darker than a red brick of the same brightness.
        let red = try XCTUnwrap(LookLibrary.builtIns.first { $0.name == "RED FILTER" })
        let redCube = try XCTUnwrap(LookLibrary.cube(for: red))
        XCTAssertLessThan(entry(redCube, 6, 14, 30).x, entry(redCube, 30, 10, 6).x)
    }
}
