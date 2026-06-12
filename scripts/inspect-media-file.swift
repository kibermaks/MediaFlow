#!/usr/bin/env swift
import AppKit
@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

func cleanedPath(from rawValue: String) -> String {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
        (value.hasPrefix("'") && value.hasSuffix("'")) {
        value = String(value.dropFirst().dropLast())
    }
    if value.hasPrefix("file://"), let url = URL(string: value) {
        return url.path
    }
    value = value
        .replacingOccurrences(of: "\\ ", with: " ")
        .replacingOccurrences(of: "\\(", with: "(")
        .replacingOccurrences(of: "\\)", with: ")")
        .replacingOccurrences(of: "\\[", with: "[")
        .replacingOccurrences(of: "\\]", with: "]")
        .replacingOccurrences(of: "\\&", with: "&")
    return (value as NSString).expandingTildeInPath
}

func promptForPath() -> String {
    print("Drag/paste image or video path, then press Return:")
    print("> ", terminator: "")
    return readLine() ?? ""
}

func byteCountString(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
}

func jsonSafeValue(_ value: Any) -> Any {
    if let dict = value as? [AnyHashable: Any] {
        return dict.reduce(into: [String: Any]()) { result, entry in
            result[String(describing: entry.key)] = jsonSafeValue(entry.value)
        }
    }
    if let array = value as? [Any] {
        return array.map(jsonSafeValue)
    }
    if let data = value as? Data {
        return "<Data \(data.count) bytes>"
    }
    if CFGetTypeID(value as CFTypeRef) == CFDataGetTypeID() {
        let data = value as! CFData
        return "<Data \(CFDataGetLength(data)) bytes>"
    }
    if let date = value as? Date {
        return ISO8601DateFormatter().string(from: date)
    }
    if let url = value as? URL {
        return url.absoluteString
    }
    if value is String || value is NSNumber || value is NSNull {
        return value
    }
    return String(describing: value)
}

func printJSON(_ value: Any) {
    let safe = jsonSafeValue(value)
    guard JSONSerialization.isValidJSONObject(safe),
          let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        print(String(describing: value))
        return
    }
    print(string)
}

func printKV(_ key: String, _ value: Any?) {
    print("\(key): \(value.map { String(describing: $0) } ?? "nil")")
}

func colorSpaceSummary(_ colorSpace: CGColorSpace?) -> String {
    guard let colorSpace else { return "nil" }
    let name = colorSpace.name.map { String(describing: $0) } ?? "unnamed"
    let iccLength = colorSpace.copyICCData().map { CFDataGetLength($0) }
    return [
        "name=\(name)",
        "model=\(String(describing: colorSpace.model))",
        "components=\(colorSpace.numberOfComponents)",
        "iccBytes=\(iccLength.map(String.init) ?? "nil")"
    ].joined(separator: " ")
}

func fourCC(_ value: OSType) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
       let string = String(bytes: bytes, encoding: .macOSRoman) {
        return string
    }
    return "\(value)"
}

func secondsString(_ time: CMTime) -> String {
    guard time.isNumeric else { return String(describing: time) }
    return String(format: "%.3fs", time.seconds)
}

func affineSummary(_ transform: CGAffineTransform) -> String {
    "a=\(transform.a) b=\(transform.b) c=\(transform.c) d=\(transform.d) tx=\(transform.tx) ty=\(transform.ty)"
}

func displaySize(encodedSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
    guard encodedSize.width > 0, encodedSize.height > 0 else { return encodedSize }
    return CGRect(origin: .zero, size: encodedSize).applying(preferredTransform).standardized.size
}

func auxiliaryInfo(_ source: CGImageSource, type: CFString) -> Any? {
    CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type)
}

func hasAuxiliaryInfo(_ source: CGImageSource, type: CFString) -> Bool {
    auxiliaryInfo(source, type: type) != nil
}

func mediaFlowImageDynamicRangeGuess(source: CGImageSource?, ciImage: CIImage?) -> String {
    guard let source,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        if #available(macOS 15.0, *), let ciImage, ciImage.contentHeadroom > 1.01 {
            return "adaptiveHDR"
        }
        return "standard"
    }
    let description = properties
        .map { "\(String(describing: $0.key))=\(String(describing: $0.value))" }
        .joined(separator: " ")
        .lowercased()
    if description.contains("hlg") || description.contains("arib") || description.contains("b67") {
        return "hlg"
    }
    if description.contains("pq") || description.contains("2084") {
        return "pq"
    }
    if #available(macOS 15.0, *), let ciImage, ciImage.contentHeadroom > 1.01 {
        return "adaptiveHDR"
    }
    if hasAuxiliaryInfo(source, type: kCGImageAuxiliaryDataTypeHDRGainMap) {
        return "adaptiveHDR"
    }
    if #available(macOS 15.0, *),
       hasAuxiliaryInfo(source, type: kCGImageAuxiliaryDataTypeISOGainMap) {
        return "adaptiveHDR"
    }
    if description.contains("display p3") ||
        description.contains("display-p3") ||
        description.contains("p3") ||
        description.contains("2020") {
        return "wide"
    }
    return "standard"
}

func mediaFlowVideoDynamicRangeGuess(formatDescriptions: [CMFormatDescription]) -> String {
    var fallback = "standard"
    for formatDescription in formatDescriptions {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] else { continue }
        let transfer = String(describing: extensions[kCMFormatDescriptionExtension_TransferFunction] ?? "").lowercased()
        let primaries = String(describing: extensions[kCMFormatDescriptionExtension_ColorPrimaries] ?? "").lowercased()
        let matrix = String(describing: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] ?? "").lowercased()
        let combined = "\(transfer) \(primaries) \(matrix)"
        if combined.contains("hlg") || combined.contains("arib") || combined.contains("b67") || combined.contains("2100") {
            return "hlg"
        }
        if combined.contains("pq") || combined.contains("2084") {
            return "pq"
        }
        if combined.contains("2020") || combined.contains("p3") {
            fallback = "wide"
        }
    }
    return fallback
}

func printImageDiagnostics(for fileURL: URL) -> Bool {
    let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, imageSourceOptions),
          CGImageSourceGetCount(source) > 0 else {
        print("")
        print("=== ImageIO ===")
        print("ImageIO: no still-image source.")
        return false
    }

    print("")
    print("=== ImageIO Summary ===")
    printKV("ImageIO type", CGImageSourceGetType(source))
    printKV("Image count", CGImageSourceGetCount(source))

    let containerProperties = CGImageSourceCopyProperties(source, nil)
    let imageProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
    let imageDict = imageProperties as? [CFString: Any]

    if let imageDict {
        printKV("Pixel width", imageDict[kCGImagePropertyPixelWidth])
        printKV("Pixel height", imageDict[kCGImagePropertyPixelHeight])
        printKV("Orientation", imageDict[kCGImagePropertyOrientation])
        printKV("Color model", imageDict[kCGImagePropertyColorModel])
        printKV("Depth", imageDict[kCGImagePropertyDepth])
        printKV("Has alpha", imageDict[kCGImagePropertyHasAlpha])
        printKV("Profile name", imageDict[kCGImagePropertyProfileName])
        printKV("DPI width", imageDict[kCGImagePropertyDPIWidth])
        printKV("DPI height", imageDict[kCGImagePropertyDPIHeight])
    }

    print("")
    print("=== Auxiliary Image Data ===")
    printKV("HDR gain map", hasAuxiliaryInfo(source, type: kCGImageAuxiliaryDataTypeHDRGainMap))
    if #available(macOS 15.0, *) {
        printKV("ISO gain map", hasAuxiliaryInfo(source, type: kCGImageAuxiliaryDataTypeISOGainMap))
    }

    var ciOptions: [CIImageOption: Any] = [
        .applyOrientationProperty: true,
        .toneMapHDRtoSDR: false
    ]
    if #available(macOS 14.0, *) {
        ciOptions[.expandToHDR] = true
    }
    let ciImage = CIImage(contentsOf: fileURL, options: ciOptions)

    print("")
    print("=== Core Image Decode ===")
    if let ciImage {
        printKV("CI extent", ciImage.extent)
        printKV("CI color space", colorSpaceSummary(ciImage.colorSpace))
        if #available(macOS 15.0, *) {
            printKV("CI contentHeadroom", ciImage.contentHeadroom)
        }
        printKV("MediaFlow image dynamic range guess", mediaFlowImageDynamicRangeGuess(source: source, ciImage: ciImage))
    } else {
        print("CIImage(contentsOf:) failed.")
        printKV("MediaFlow image dynamic range guess", mediaFlowImageDynamicRangeGuess(source: source, ciImage: nil))
    }

    print("")
    print("=== CGImage Decode ===")
    let decodeOptions = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldAllowFloat: true
    ] as CFDictionary
    if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions) {
        printKV("CGImage size", "\(cgImage.width)x\(cgImage.height)")
        printKV("CGImage color space", colorSpaceSummary(cgImage.colorSpace))
        printKV("Bits/component", cgImage.bitsPerComponent)
        printKV("Bits/pixel", cgImage.bitsPerPixel)
        printKV("Bytes/row", cgImage.bytesPerRow)
        printKV("Alpha info", cgImage.alphaInfo)
        printKV("Bitmap info raw", cgImage.bitmapInfo.rawValue)
    } else {
        print("CGImageSourceCreateImageAtIndex failed.")
    }

    if let containerProperties {
        print("")
        print("=== Full ImageIO Container Properties ===")
        printJSON(containerProperties)
    }

    if let imageProperties {
        print("")
        print("=== Full ImageIO Image Properties ===")
        printJSON(imageProperties)
    }

    if let hdrGainMap = auxiliaryInfo(source, type: kCGImageAuxiliaryDataTypeHDRGainMap) {
        print("")
        print("=== HDR Gain Map Info ===")
        printJSON(hdrGainMap)
    }

    if #available(macOS 15.0, *),
       let isoGainMap = auxiliaryInfo(source, type: kCGImageAuxiliaryDataTypeISOGainMap) {
        print("")
        print("=== ISO Gain Map Info ===")
        printJSON(isoGainMap)
    }

    return true
}

func printFormatDescription(_ formatDescription: CMFormatDescription, index: Int) {
    let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
    let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
    print("")
    print("=== Video Format Description \(index) ===")
    printKV("Media type", fourCC(mediaType))
    printKV("Codec/subtype", fourCC(mediaSubType))
    if mediaType == kCMMediaType_Video {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        printKV("Encoded dimensions", "\(dimensions.width)x\(dimensions.height)")
    }
    if let extensions = CMFormatDescriptionGetExtensions(formatDescription) {
        let dict = extensions as NSDictionary
        printKV("Color primaries", dict[kCMFormatDescriptionExtension_ColorPrimaries])
        printKV("Transfer function", dict[kCMFormatDescriptionExtension_TransferFunction])
        printKV("YCbCr matrix", dict[kCMFormatDescriptionExtension_YCbCrMatrix])
        printKV("Full range video", dict[kCMFormatDescriptionExtension_FullRangeVideo])
        printKV("Content light level", dict[kCMFormatDescriptionExtension_ContentLightLevelInfo])
        printKV("Mastering display color volume", dict[kCMFormatDescriptionExtension_MasteringDisplayColorVolume])
        print("")
        print("Full format extensions:")
        printJSON(extensions)
    }
}

func printVideoTrack(_ track: AVAssetTrack, index: Int) async -> [CMFormatDescription] {
    print("")
    print("=== AVFoundation Video Track \(index) ===")
    do {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let estimatedDataRate = try await track.load(.estimatedDataRate)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let display = displaySize(encodedSize: naturalSize, preferredTransform: preferredTransform)

        printKV("Natural size", naturalSize)
        printKV("Display size after transform", display)
        printKV("Preferred transform", affineSummary(preferredTransform))
        printKV("Nominal frame rate", nominalFrameRate)
        printKV("Estimated data rate", "\(estimatedDataRate) bps")
        printKV("Format description count", formatDescriptions.count)
        printKV("MediaFlow video dynamic range guess", mediaFlowVideoDynamicRangeGuess(formatDescriptions: formatDescriptions))
        let outputPixelFormat = mediaFlowVideoDynamicRangeGuess(formatDescriptions: formatDescriptions) == "standard" ||
            mediaFlowVideoDynamicRangeGuess(formatDescriptions: formatDescriptions) == "wide"
            ? "32BGRA"
            : "64RGBAHalf"
        printKV("MediaFlow video output pixel format guess", outputPixelFormat)

        for (formatIndex, formatDescription) in formatDescriptions.enumerated() {
            printFormatDescription(formatDescription, index: formatIndex)
        }
        return formatDescriptions
    } catch {
        print("Video track load failed: \(error)")
        return []
    }
}

func printVideoDiagnostics(for fileURL: URL, printFailure: Bool) async -> Bool {
    let asset = AVURLAsset(url: fileURL)
    do {
        let duration = try? await asset.load(.duration)
        let isPlayable = try? await asset.load(.isPlayable)
        let isReadable = try? await asset.load(.isReadable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            if printFailure {
                print("")
                print("=== AVFoundation ===")
                print("AVFoundation: no audio/video tracks.")
            }
            return false
        }

        print("")
        print("=== AVFoundation Asset Summary ===")
        if let duration {
            printKV("Duration", secondsString(duration))
        }
        printKV("Playable", isPlayable)
        printKV("Readable", isReadable)
        printKV("Video track count", videoTracks.count)
        printKV("Audio track count", audioTracks.count)

        var allFormatDescriptions: [CMFormatDescription] = []
        for (index, track) in videoTracks.enumerated() {
            allFormatDescriptions.append(contentsOf: await printVideoTrack(track, index: index))
        }
        if !allFormatDescriptions.isEmpty {
            print("")
            print("=== MediaFlow Video Summary ===")
            let dynamicRange = mediaFlowVideoDynamicRangeGuess(formatDescriptions: allFormatDescriptions)
            printKV("Dynamic range guess", dynamicRange)
            printKV("Uses EDR", dynamicRange == "adaptiveHDR" || dynamicRange == "hlg" || dynamicRange == "pq")
        }
        return true
    } catch {
        if printFailure {
            print("")
            print("=== AVFoundation ===")
            print("AVFoundation load failed: \(error)")
        }
        return false
    }
}

let rawPath = CommandLine.arguments.dropFirst().isEmpty
    ? promptForPath()
    : CommandLine.arguments.dropFirst().joined(separator: " ")
let fileURL = URL(fileURLWithPath: cleanedPath(from: rawPath))

guard FileManager.default.fileExists(atPath: fileURL.path) else {
    fputs("File not found: \(fileURL.path)\n", stderr)
    exit(1)
}

print("=== MediaFlow Media Diagnostic ===")
printKV("Path", fileURL.path)

let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
if let size = attributes[.size] as? UInt64 {
    printKV("File size", "\(byteCountString(size)) (\(size) bytes)")
}
printKV("Modified", attributes[.modificationDate])
printKV("Extension UTType", UTType(filenameExtension: fileURL.pathExtension)?.identifier)

let printedImage = printImageDiagnostics(for: fileURL)
let printedVideo = await printVideoDiagnostics(for: fileURL, printFailure: !printedImage)

if !printedImage && !printedVideo {
    exit(2)
}
