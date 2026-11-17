import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
@testable import ClicksmithCore

/// Native codecs run in an expendable process, never in discovery or a Swift task awaiting a codec.
/// A failed/timed-out capability check is reported as SKIP, not as a successful conversion.
/// Once the capability check passes, any failure/timeout is a test failure.
enum ImageNativeTest {
    static var isWorker: Bool { ProcessInfo.processInfo.environment["CLICKSMITH_IMAGE_NATIVE_CASE"] != nil }

    @discardableResult
    static func run(_ name: String, format: ImageFormat = .heic, timeout: TimeInterval = 12) throws -> Bool {
        let files = try ImageTestFiles()
        defer { files.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
            process.arguments = ["--test-bundle-path", CommandLine.arguments[index + 1],
                                 "--filter", "imageNativeCodecWorker", "--testing-library", "swift-testing"]
        } else {
            process.arguments = ["--filter", "imageNativeCodecWorker", "--testing-library", "swift-testing"]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CLICKSMITH_IMAGE_NATIVE_CASE"] = name
        environment["CLICKSMITH_IMAGE_NATIVE_FORMAT"] = format.rawValue
        environment["CLICKSMITH_IMAGE_NATIVE_READY"] = files.url("ready").path
        process.environment = environment
        let log = files.url("native.log")
        #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let timedOut = process.isRunning
        if timedOut { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let transcript = try String(contentsOf: log, encoding: .utf8)
        if timedOut && !FileManager.default.fileExists(atPath: files.url("ready").path) {
            if name == "simulated-stall" {
                print("PASS native watchdog: deliberately stalled child killed after \(timeout) seconds")
            } else {
                print("SKIP native \(name)/\(format.rawValue): encoder capability check exceeded \(timeout) seconds; child killed")
            }
        } else {
            let skips = transcript.split(separator: "\n").filter { $0.contains("SKIP") }
            if !skips.isEmpty {
                for line in skips {
                    if let start = line.range(of: "SKIP")?.lowerBound { print(line[start...]) }
                }
            } else if process.terminationStatus == 0 {
                print("PASS native \(name)/\(format.rawValue): child assertions completed")
            }
            #expect(!timedOut, "Native operation hung after its capability check passed")
            #expect(process.terminationStatus == 0, "Native child failed: \(transcript)")
        }
        return timedOut
    }

    static func checkCapability(_ kind: String, format: ImageFormat) throws -> Bool {
        let type = kind == "heics" || kind == "animation" ? "public.heics" : format.typeIdentifier
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type) else {
            print("SKIP native \(kind): no ImageIO writer for \(type)")
            return false
        }
        let files = try ImageTestFiles()
        defer { files.remove() }
        let count = kind == "collection" || type == "public.heics" ? 2 : 1
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, count, nil) else {
            print("SKIP native \(kind): cannot create \(type) destination")
            return false
        }
        let image = try files.image(width: 64, height: 64)
        for _ in 0..<count { CGImageDestinationAddImage(destination, image, nil) }
        guard CGImageDestinationFinalize(destination) else {
            print("SKIP native \(kind): \(type) encoder cannot finalize in this environment")
            return false
        }
        let readyPath = try #require(ProcessInfo.processInfo.environment["CLICKSMITH_IMAGE_NATIVE_READY"])
        try Data().write(to: URL(fileURLWithPath: readyPath))
        return true
    }
}

@Test(.enabled(if: ImageNativeTest.isWorker, "Runs only as a bounded native-codec child process"))
func imageNativeCodecWorker() throws {
    let environment = ProcessInfo.processInfo.environment
    let kind = try #require(environment["CLICKSMITH_IMAGE_NATIVE_CASE"])
    if kind == "simulated-stall" { Thread.sleep(forTimeInterval: 60); return }
    let format = try #require(ImageFormat(rawValue: environment["CLICKSMITH_IMAGE_NATIVE_FORMAT"] ?? ""))
    guard try ImageNativeTest.checkCapability(kind, format: format) else { return }
    switch kind {
    case "roundtrip": try imageRoundTripEveryAdvertisedFormat(format: format)
    case "animation": try imageAnimationRetainsFramesAndTiming(format: .heic)
    case "heics": try imageHEICSInputRetainsAnimationWhenEncoderIsAvailable()
    case "collection": try imageGeneratedHEIFCollectionStaysStill()
    default: Issue.record("Unknown native test case \(kind)")
    }
}

@Test func imageNativeTestKillsAStalledEncoderProcess() throws {
    #expect(try ImageNativeTest.run("simulated-stall", timeout: 0.5))
}

@Test func imageGeneratedHEIFCollectionStaysStill() throws {
    if !ImageNativeTest.isWorker { try ImageNativeTest.run("collection"); return }
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = files.url("collection.heic")
    let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, "public.heic" as CFString, 2, nil))
    CGImageDestinationAddImage(destination, try files.image(blue: true), [kCGImagePropertyPrimaryImage: true] as CFDictionary)
    CGImageDestinationAddImage(destination, try files.image(), [kCGImagePropertyPrimaryImage: false] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    let source = try files.source(input)
    #expect(CGImageSourceGetCount(source) == 2)
    #expect(try !ImageInput(input).isAnimation)
    for format in [ImageFormat.heic, .png, .gif, .tiff, .pdf] {
        let output = files.url("still.\(format.rawValue)")
        try ImageEngine.convert(input, to: format, options: ImageConvertOptions(maxPixelSize: 32), output: output)
        #expect(try ImageEngine.info(output).frameCount == 1)
        if format != .pdf { #expect(try files.pixel(output)[2] > 230) }
    }
    let resized = files.url("resized.heic")
    try ImageEngine.resize(input, maxPixelSize: 20, output: resized)
    #expect(try ImageEngine.info(resized).frameCount == 1)
    #expect(CGImageSourceGetType(try files.source(resized)) as String? == "public.heic")
}
