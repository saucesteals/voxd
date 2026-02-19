import Testing
import Foundation
import voxd

struct ProcessorTests {

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

    private func silenceFrame() -> [UInt8] {
        [UInt8](repeating: 0, count: 960 * 2)
    }

    private func countEvents(_ outputs: [[ProcessorOutput]]) -> (starts: Int, ends: Int) {
        var s = 0, e = 0
        for batch in outputs {
            for o in batch {
                if o.msgType == kMsgSpeechStart { s += 1 }
                if o.msgType == kMsgSpeechEnd { e += 1 }
            }
        }
        return (s, e)
    }

    @Test func silenceProducesNoEvents() throws {
        let model = try #require(Self.model, "silero_vad.onnx not found")
        let proc = AudioProcessor(model: model)
        let silence = silenceFrame()
        let outputs = (0..<100).map { _ in proc.processAudio(samples: silence, streamID: 1, timeMs: 0) }
        let (starts, ends) = countEvents(outputs)

        #expect(starts == 0)
        #expect(ends == 0)
    }

    @Test func outputTypesAreValid() throws {
        let model = try #require(Self.model, "silero_vad.onnx not found")
        let proc = AudioProcessor(model: model)
        let silence = silenceFrame()

        let validTypes: Set<UInt8> = [kMsgOutAudio, kMsgSpeechStart, kMsgSpeechEnd]
        for _ in 0..<50 {
            for o in proc.processAudio(samples: silence, streamID: 1, timeMs: 0) {
                #expect(validTypes.contains(o.msgType))
            }
        }
    }
}
