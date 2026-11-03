import CoreGraphics
import Foundation
import Testing
@testable import UltraViewerProtocol

/// Opt-in release benchmark of a complete drawing mission on a 4K desktop.
/// MACVIEWER_PIXEL_BENCHMARK=1 swift test -c release --filter rendererFrameReleaseBenchmark
///
/// Each frame changes one small rectangle, as typing or a blinking caret does,
/// while the previous frame's CGImage is still held the way the screen view
/// holds it. The cost measured is therefore dominated by per-frame overhead
/// (buffer copies and allocations), not by the changed pixels themselves.
/// No captured screen content, target execution or network access is involved.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACVIEWER_PIXEL_BENCHMARK"] == "1"))
func rendererFrameReleaseBenchmark() throws {
    let width = 3840, height = 2160, side = 128, warmup = 5, iterations = 120
    let renderer = try ModernScreenRenderer(width: width, height: height, displayColors: 0, lastFrameNumber: 0)

    func words(_ values: [Int]) -> Data {
        Data(values.flatMap { value -> [UInt8] in
            let bits = UInt16(truncatingIfNeeded: value)
            return [UInt8(truncatingIfNeeded: bits), UInt8(bits >> 8)]
        })
    }
    func long(_ value: Int32) -> Data {
        let bits = UInt32(bitPattern: value)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
    }
    var raw = Data(count: side * side * 2)
    raw.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for index in 0..<(side * side) {
            let value = UInt16(truncatingIfNeeded: index * 73 ^ (index >> 5)) & 0x7fff
            bytes[index * 2] = UInt8(truncatingIfNeeded: value)
            bytes[index * 2 + 1] = UInt8(value >> 8)
        }
    }
    let compressed = try ZstdScreenEncoder.encode(raw)
    func frame(_ number: Int) throws -> ModernScreenFrameMessage {
        let x = (number * 97) % (width - side), y = (number * 53) % (height - side)
        return try ModernScreenFrameMessage.decode(parts: [
            Data([1]), words([x, y, side, side]), compressed, Data(), long(Int32(number)),
            Data(), Data(), Data(), Data(), Data(), Data(),
        ])
    }
    let messages = try (1...(warmup + iterations)).map(frame)

    var shown: CGImage?
    for message in messages.prefix(warmup) {
        shown = try renderer.apply(message).makeCGImage()
    }
    let clock = ContinuousClock()
    var worst = Duration.zero
    let start = clock.now
    for message in messages.dropFirst(warmup) {
        let frameStart = clock.now
        // Like the app: the view keeps the previous image until the new one replaces it.
        shown = try renderer.apply(message).makeCGImage()
        worst = max(worst, frameStart.duration(to: clock.now))
    }
    let total = start.duration(to: clock.now)
    func milliseconds(_ time: Duration) -> Double {
        Double(time.components.seconds) * 1000 + Double(time.components.attoseconds) / 1e15
    }
    let report: [String: Any] = [
        "benchmark": "4K drawing mission, one \(side)x\(side) rectangle, previous image held",
        "iterations": iterations,
        "averageMillisecondsPerFrame": milliseconds(total) / Double(iterations),
        "worstMillisecondsPerFrame": milliseconds(worst),
        "framesPerSecondCeiling": Double(iterations) / (milliseconds(total) / 1000),
    ]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    #expect(shown?.width == width)
    #expect(renderer.lastFrameNumber == Int32(warmup + iterations))
}
