import Testing
import Foundation
import voxd

struct ProcessorTests {

    /// Generate a 20ms frame of PCM16LE at 48kHz.
    private func frame(frequency: Double = 0, amplitude: Double = 0) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 960 * 2)
        for i in 0..<960 {
            let sample = Int16(sin(2.0 * .pi * frequency * Double(i) / 48000.0) * amplitude)
            let u = UInt16(bitPattern: sample)
            buf[i * 2]     = UInt8(u & 0xff)
            buf[i * 2 + 1] = UInt8(u >> 8)
        }
        return buf
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

    @Test func silenceProducesNoEvents() {
        let proc = AudioProcessor(model: nil)
        let silence = frame()
        let outputs = (0..<100).map { _ in proc.processAudio(samples: silence, streamID: 1, timeMs: 0) }
        let (starts, ends) = countEvents(outputs)

        #expect(starts == 0)
        #expect(ends == 0)
    }

    @Test func loudAudioTriggersBoundaries() {
        let proc = AudioProcessor(model: nil)
        let loud = frame(frequency: 300, amplitude: 30000)
        let silence = frame()

        var all: [[ProcessorOutput]] = []
        for _ in 0..<50 { all.append(proc.processAudio(samples: loud, streamID: 1, timeMs: 0)) }
        for _ in 0..<50 { all.append(proc.processAudio(samples: silence, streamID: 1, timeMs: 0)) }

        let (starts, ends) = countEvents(all)
        #expect(starts > 0, "Loud audio should trigger speech start")
        #expect(ends > 0, "Silence after loud audio should trigger speech end")
    }
}
