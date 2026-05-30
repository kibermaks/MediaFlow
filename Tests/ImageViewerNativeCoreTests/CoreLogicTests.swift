import CoreGraphics
import XCTest
@testable import ImageViewerNativeCore

final class CoreLogicTests: XCTestCase {
    func testDynamicRangeEDRClassification() {
        XCTAssertFalse(MediaDynamicRange.standard.usesEDR)
        XCTAssertFalse(MediaDynamicRange.wide.usesEDR)
        XCTAssertTrue(MediaDynamicRange.adaptiveHDR.usesEDR)
        XCTAssertTrue(MediaDynamicRange.hlg.usesEDR)
        XCTAssertTrue(MediaDynamicRange.pq.usesEDR)
    }

    func testMetalQualitySamplingModes() {
        XCTAssertEqual(MetalQualityMode.best.shaderSamplingMode(isMinifying: true), 0)
        XCTAssertEqual(MetalQualityMode.best.shaderSamplingMode(isMinifying: false), 3)
        XCTAssertEqual(MetalQualityMode.nearest.shaderSamplingMode(isMinifying: false), 1)
        XCTAssertEqual(MetalQualityMode.bicubic.shaderSamplingMode(isMinifying: false), 2)
    }

    func testVideoTextureMappingRejectsInvalidSizes() {
        XCTAssertNil(VideoTextureMapping.make(encodedSize: .zero, preferredTransform: .identity))
        XCTAssertNil(VideoTextureMapping.make(encodedSize: CGSize(width: CGFloat.infinity, height: 1080), preferredTransform: .identity))
    }

    func testVideoTextureMappingIdentityCoordinates() throws {
        let mapping = try XCTUnwrap(VideoTextureMapping.make(
            encodedSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        ))

        XCTAssertEqual(mapping.displayRect.size.width, 1920, accuracy: 0.001)
        XCTAssertEqual(mapping.displayRect.size.height, 1080, accuracy: 0.001)

        let uv = mapping.textureCoordinate(displayUV: SIMD2<Float>(0.25, 0.75))
        XCTAssertEqual(uv.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(uv.y, 0.75, accuracy: 0.001)
    }

    func testPlaybackSaveURLNormalizesExtension() {
        let duplicate = URL(fileURLWithPath: "/tmp/collage.ivplayback.ivplayback")
        XCTAssertEqual(PlaybackFile.normalizedSaveURL(duplicate).lastPathComponent, "collage.ivplayback")

        let missing = URL(fileURLWithPath: "/tmp/collage")
        XCTAssertEqual(PlaybackFile.normalizedSaveURL(missing).lastPathComponent, "collage.ivplayback")
    }

    func testChangelogParserBuildsVersionedSections() {
        let markdown = """
        # Changelog

        ## [0.4] - 2026-05-30

        ### Added
        - Debug Information overlay.
        - Photos import browser.

        ### Changed
        - Quality Controls now uses compact switches.

        ## [0.3] - 2026-05-29

        ### Fixed
        - Bundled changelog loading.
        """

        let entries = MediaFlowChangelogService.parse(markdown)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].version, "0.4")
        XCTAssertEqual(entries[0].date, "2026-05-30")
        XCTAssertEqual(entries[0].sections.count, 2)
        XCTAssertEqual(entries[0].sections[0].category, "Added")
        XCTAssertEqual(entries[0].sections[0].items, ["Debug Information overlay.", "Photos import browser."])
        XCTAssertEqual(entries[0].sections[1].category, "Changed")
        XCTAssertEqual(entries[1].version, "0.3")
        XCTAssertEqual(entries[1].sections[0].category, "Fixed")
    }

    func testChangelogVersionComparisonUsesNumericComponents() {
        XCTAssertEqual(MediaFlowChangelogService.compareVersion(lhs: "0.10", rhs: "0.9"), .orderedDescending)
        XCTAssertEqual(MediaFlowChangelogService.compareVersion(lhs: "1.0.0", rhs: "1"), .orderedSame)
        XCTAssertEqual(MediaFlowChangelogService.compareVersion(lhs: "0.4", rhs: "0.4.1"), .orderedAscending)
    }

    func testItemRotationSwapsVisibleAspect() {
        let item = CollageItem(
            url: URL(fileURLWithPath: "/tmp/example.jpg"),
            kind: .image,
            pixelSize: CGSize(width: 100, height: 50),
            texture: nil
        )

        XCTAssertEqual(item.visibleAspect, 2, accuracy: 0.001)
        item.rotationQuarterTurns = 1
        XCTAssertEqual(item.visibleAspect, 0.5, accuracy: 0.001)
        item.rotationQuarterTurns = -1
        XCTAssertEqual(item.rotationQuarterTurns, 3)
        item.rotationQuarterTurns = item.rotationQuarterTurns + 2
        XCTAssertEqual(item.rotationQuarterTurns, 1)
    }

    func testPlaybackRateUsesForwardSpeed() {
        let item = CollageItem(
            url: URL(fileURLWithPath: "/tmp/example.mov"),
            kind: .video,
            pixelSize: CGSize(width: 1920, height: 1080),
            texture: nil
        )

        item.speed = 1.25

        XCTAssertEqual(item.playbackRate, 1.25, accuracy: 0.001)
    }

    func testLegacySwingPlaybackModeDoesNotBlockSavedItemDecode() throws {
        let data = Data("""
        {
          "path": "/tmp/example.mov",
          "weight": 1,
          "zoom": 1,
          "panX": 0,
          "panY": 0,
          "speed": 1,
          "volume": 1,
          "muted": false,
          "playbackMode": 1,
          "swingDirection": -1,
          "abLoops": []
        }
        """.utf8)

        let saved = try JSONDecoder().decode(SavedItem.self, from: data)

        XCTAssertEqual(saved.path, "/tmp/example.mov")
        XCTAssertEqual(saved.speed, 1)
        XCTAssertTrue(saved.abLoops.isEmpty)
    }
}
