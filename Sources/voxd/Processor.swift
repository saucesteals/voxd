import Foundation

// MARK: - Processor output

/// A message produced by the audio processor in response to an input frame.
public struct ProcessorOutput {
    public let msgType: UInt8
    public let timeMs: UInt64
    public let payload: [UInt8]
}

// MARK: - Gate config

/// VAD gate parameters controlling speech boundary detection.
public struct GateConfig {
    public let startThreshold: Float
    public let endThreshold: Float
    public let minSpeechMs: Int
    public let minSilenceMs: Int
    public let preRollMs: Int
    public let logVAD: Bool

    public static let `default` = GateConfig()

    public init(
        startThreshold: Float = 0.40,
        endThreshold: Float = 0.30,
        minSpeechMs: Int = 120,
        minSilenceMs: Int = 250,
        preRollMs: Int = 300,
        logVAD: Bool = false
    ) {
        self.startThreshold = startThreshold
        self.endThreshold = endThreshold
        self.minSpeechMs = minSpeechMs
        self.minSilenceMs = minSilenceMs
        self.preRollMs = preRollMs
        self.logVAD = logVAD
    }

    static let sampleRate = 48000
    static let frameMs = 20

    var minSpeechFrames: Int { (minSpeechMs + Self.frameMs - 1) / Self.frameMs }
    var minSilenceFrames: Int { (minSilenceMs + Self.frameMs - 1) / Self.frameMs }
    var preRollFrames: Int { (preRollMs + Self.frameMs - 1) / Self.frameMs }
}

// MARK: - Gate state machine

private enum GateState {
    case idle
    case maybeSpeech(frames: Int)
    case speech
    case maybeSilence(frames: Int)
}

// MARK: - Audio processor

/// Processes incoming PCM16LE audio frames through VAD and emits speech boundary events.
///
/// Each processor holds its own gate state and VAD stream. Create one per connection.
public class AudioProcessor {
    private let config: GateConfig
    private var state: GateState = .idle
    private var preRollBuffer: [[Int16]] = []
    private let vadStream: SileroVADStream
    private var lastProb: Float = 0

    public init(model: SileroVADModel, config: GateConfig = .default) {
        self.config = config
        self.vadStream = model.newStream()
    }

    /// Process one audio frame (raw PCM16LE bytes at 48kHz).
    ///
    /// Returns zero or more output messages: `SPEECH_START`, `OUT_AUDIO`, or `SPEECH_END`.
    public func processAudio(samples rawBytes: [UInt8], streamID: UInt64, timeMs: UInt64) -> [ProcessorOutput] {
        let sampleCount = rawBytes.count / 2
        guard sampleCount > 0 else { return [] }

        // Decode PCM16LE
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            samples[i] = Int16(bitPattern: UInt16(rawBytes[i * 2]) | UInt16(rawBytes[i * 2 + 1]) << 8)
        }

        let prob = computeProbability(samples)
        lastProb = prob

        if config.logVAD && prob > 0.05 {
            fputs("[vad] p=\(String(format: "%.3f", prob))\n", stderr)
        }

        // Pre-roll ring buffer
        preRollBuffer.append(samples)
        if preRollBuffer.count > config.preRollFrames {
            preRollBuffer.removeFirst(preRollBuffer.count - config.preRollFrames)
        }

        return runGate(samples: samples, prob: prob, timeMs: timeMs)
    }

    // MARK: - Private

    private func computeProbability(_ samples: [Int16]) -> Float {
        vadStream.feedSamples48kHz(samples).last ?? lastProb
    }

    private func runGate(samples: [Int16], prob: Float, timeMs: UInt64) -> [ProcessorOutput] {
        var outputs: [ProcessorOutput] = []

        switch state {
        case .idle:
            if prob >= config.startThreshold {
                state = .maybeSpeech(frames: 1)
            }

        case .maybeSpeech(let n):
            if prob >= config.startThreshold {
                if n + 1 >= config.minSpeechFrames {
                    outputs.append(ProcessorOutput(msgType: kMsgSpeechStart, timeMs: timeMs, payload: []))
                    for frame in preRollBuffer {
                        outputs.append(encodePCM(frame, timeMs: timeMs))
                    }
                    state = .speech
                } else {
                    state = .maybeSpeech(frames: n + 1)
                }
            } else {
                state = .idle
            }

        case .speech:
            outputs.append(encodePCM(samples, timeMs: timeMs))
            if prob < config.endThreshold {
                state = .maybeSilence(frames: 1)
            }

        case .maybeSilence(let n):
            outputs.append(encodePCM(samples, timeMs: timeMs))
            if prob < config.endThreshold {
                if n + 1 >= config.minSilenceFrames {
                    outputs.append(ProcessorOutput(msgType: kMsgSpeechEnd, timeMs: timeMs, payload: []))
                    state = .idle
                    preRollBuffer.removeAll()
                    vadStream.resetState()
                } else {
                    state = .maybeSilence(frames: n + 1)
                }
            } else {
                state = .speech
            }
        }

        return outputs
    }

    private func encodePCM(_ samples: [Int16], timeMs: UInt64) -> ProcessorOutput {
        var bytes = [UInt8](repeating: 0, count: samples.count * 2)
        for (i, s) in samples.enumerated() {
            let u = UInt16(bitPattern: s)
            bytes[i * 2]     = UInt8(u & 0xff)
            bytes[i * 2 + 1] = UInt8(u >> 8)
        }
        return ProcessorOutput(msgType: kMsgOutAudio, timeMs: timeMs, payload: bytes)
    }
}
