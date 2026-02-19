import Testing
import Foundation
import voxd

struct SileroVADTests {

    private static let model: SileroVADModel? = {
        let paths = [
            ProcessInfo.processInfo.environment["VOXD_MODEL_PATH"],
            {
                let home = ProcessInfo.processInfo.environment["HOME"] ?? "."
                let p = "\(home)/models/vad/silero_vad.onnx"
                return FileManager.default.fileExists(atPath: p) ? p : nil
            }(),
        ].compactMap { $0 }

        guard let path = paths.first else { return nil }
        return try? SileroVADModel(modelPath: path)
    }()

    /// 20ms of silence at 48kHz
    private let silence = [Int16](repeating: 0, count: 960)

    /// 20ms of 440Hz tone at 48kHz
    private var tone: [Int16] {
        (0..<960).map { i in Int16(sin(2.0 * .pi * 440.0 * Double(i) / 48000.0) * 20000) }
    }

    @Test func silenceLowProbability() throws {
        let stream = try #require(Self.model, "silero_vad.onnx not found").newStream()
        for p in stream.feedSamples48kHz(silence) {
            #expect(p >= 0 && p <= 1)
            #expect(p < 0.15)
        }
    }

    @Test func stressTest() throws {
        let stream = try #require(Self.model).newStream()
        for _ in 0..<50 { _ = stream.feedSamples48kHz(silence) }
    }

    @Test func resetClearsState() throws {
        let stream = try #require(Self.model).newStream()
        for _ in 0..<10 { _ = stream.feedSamples48kHz(tone) }
        stream.resetState()
        for p in stream.feedSamples48kHz(silence) {
            #expect(p < 0.15)
        }
    }

    @Test func isolatedStreams() throws {
        let model = try #require(Self.model)
        let s1 = model.newStream()
        let s2 = model.newStream()

        _ = s1.feedSamples48kHz(silence)
        _ = s2.feedSamples48kHz(tone)

        for p in s1.feedSamples48kHz(silence) { #expect(p >= 0 && p <= 1) }
        for p in s2.feedSamples48kHz(tone)    { #expect(p >= 0 && p <= 1) }
    }
}
