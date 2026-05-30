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
    }
}
