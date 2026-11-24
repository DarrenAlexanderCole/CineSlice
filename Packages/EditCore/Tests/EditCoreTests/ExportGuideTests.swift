import XCTest

@testable import EditCore

final class ExportGuideTests: XCTestCase {
    func testResolutionScalesTheFrameKeepingItsShape() {
        var s = ExportSettings.vertical1080
        XCTAssertEqual([s.outputWidth, s.outputHeight], [1080, 1920])
        s.resolution = 2160
        XCTAssertEqual([s.outputWidth, s.outputHeight], [2160, 3840])
        s.resolution = 720
        XCTAssertEqual([s.outputWidth, s.outputHeight], [720, 1280])
        s.cutsToFeed = true
        XCTAssertEqual([s.outputWidth, s.outputHeight], [720, 900])
        XCTAssertEqual([s.frameWidth, s.frameHeight], [720, 1280])
        // Odd results round to even pixels.
        s.cutsToFeed = false
        s.resolution = 1000
        XCTAssertEqual([s.outputWidth, s.outputHeight], [1000, 1778])
        let wide = s.oriented(landscape: true)
        XCTAssertEqual([wide.outputWidth, wide.outputHeight], [1778, 1000])
    }

    func testOlderSettingsDecodeAsTheOld1080pH264() throws {
        let json = #"{"width":1080,"height":1920,"frameRate":30,"soundPolicy":"silent"}"#
        let s = try JSONDecoder().decode(ExportSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s, ExportSettings(soundPolicy: .silent))
        XCTAssertEqual(s.resolution, 1080)
        XCTAssertEqual(s.codec, .h264)
        XCTAssertNil(s.videoBitrate)
    }

    func testManualSettingsRoundTrip() throws {
        let s = ExportSettings(
            frameRate: 60, resolution: 2160, codec: .hevc, videoBitrate: 40_000_000, audioBitrate: 128_000,
            keyframeInterval: 0.5)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: data), s)
    }

    func testAutoBitrateFollowsPixelsFrameRateAndCodec() {
        var s = ExportSettings.vertical1080
        XCTAssertEqual(s.autoVideoBitrate, 12_500_000)  // 1080×1920×30 × 0.2
        XCTAssertEqual(s.quality, .high)
        s.resolution = 2160
        XCTAssertEqual(s.autoVideoBitrate, 50_000_000)
        s.codec = .hevc
        XCTAssertEqual(s.autoVideoBitrate, 32_500_000)
        XCTAssertEqual(s.quality, .high)  // HEVC is rated in H.264 terms
        s.frameRate = 60
        XCTAssertEqual(s.autoVideoBitrate, 64_500_000)
    }

    func testQualityBandsAndSizeEstimate() {
        var s = ExportSettings.vertical1080
        s.videoBitrate = 2_000_000
        XCTAssertEqual(s.quality, .low)
        s.videoBitrate = 5_000_000
        XCTAssertEqual(s.quality, .fair)
        s.videoBitrate = 8_000_000
        XCTAssertEqual(s.quality, .good)
        s.videoBitrate = 30_000_000
        XCTAssertEqual(s.quality, .max)
        // 8 Mbps + 256 kbps for 10 s is ≈ 10.4 MB.
        s.videoBitrate = 8_000_000
        XCTAssertEqual(Double(s.estimatedBytes(seconds: 10, hasSound: true)), 10_423_200, accuracy: 1)
        XCTAssertEqual(Double(s.estimatedBytes(seconds: 10, hasSound: false)), 10_100_000, accuracy: 1)
    }

    func testPresetsSetShapeResolutionAndAutoBitrate() {
        var s = ExportSettings(soundPolicy: .silent, cutsToFeed: true, codec: .hevc, videoBitrate: 3_000_000)
        let wide4K = ExportPreset.all.first { $0.landscape && $0.resolution == 2160 }!
        s = wide4K.applied(to: s)
        XCTAssertTrue(s.isLandscape)
        XCTAssertEqual([s.outputWidth, s.outputHeight], [3840, 2160])
        XCTAssertNil(s.videoBitrate)
        XCTAssertEqual(s.codec, .hevc)  // left as chosen
        XCTAssertEqual(s.soundPolicy, .silent)
        XCTAssertTrue(wide4K.matches(s))
        XCTAssertEqual(ExportPreset.all.filter { $0.matches(s) }.count, 1)
        s.frameRate = 60
        XCTAssertFalse(wide4K.matches(s))
    }

    func testPresetIsOneUndoStep() throws {
        var p = Project(name: "P")
        var undo = UndoStack()
        try undo.perform(SetExportSettingsCommand(settings: ExportPreset.all[3].applied(to: p.exportSettings)), on: &p)
        XCTAssertEqual(p.exportSettings.resolution, 2160)
        undo.undo(&p)
        XCTAssertEqual(p.exportSettings, .vertical1080)
    }
}
