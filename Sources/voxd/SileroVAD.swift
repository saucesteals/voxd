import Foundation
import OnnxRuntimeBindings

// MARK: - Shared model

/// Shared ONNX Runtime session for Silero VAD v5.
///
/// Thread-safe for concurrent inference. Load once at startup,
/// then call `newStream()` for each connection.
public final class SileroVADModel {
    let session: ORTSession
    private let env: ORTEnv

    public init(modelPath: String) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: opts)
    }

    /// Create a per-connection VAD stream backed by this model.
    public func newStream() -> SileroVADStream {
        SileroVADStream(model: self)
    }
}

// MARK: - Per-connection stream

/// Per-connection VAD state. Owns its own LSTM hidden state and resampler buffer.
///
/// **Not thread-safe** — use one stream per connection.
public final class SileroVADStream {
    private let model: SileroVADModel
    private var stateData: NSMutableData
    private let srData: NSMutableData
    private var resampleBuffer: [Float] = []

    private static let chunkSize = 512   // Silero v5: 512 samples @ 16kHz
    private static let contextSize = 64  // Silero v5: 64 samples context window @ 16kHz
    private static let stateElements = 2 * 1 * 128

    private var contextBuffer: [Float]

    public init(model: SileroVADModel) {
        self.model = model
        self.contextBuffer = [Float](repeating: 0, count: Self.contextSize)
        stateData = NSMutableData(length: Self.stateElements * MemoryLayout<Float>.size)!
        srData = NSMutableData(length: MemoryLayout<Int64>.size)!
        var sr: Int64 = 16000
        srData.replaceBytes(in: NSRange(location: 0, length: 8), withBytes: &sr)
    }

    /// Reset LSTM state and resampler buffer. Call between utterances.
    public func resetState() {
        stateData.resetBytes(in: NSRange(location: 0, length: stateData.length))
        resampleBuffer.removeAll()
        contextBuffer = [Float](repeating: 0, count: Self.contextSize)
    }

    /// Feed 48kHz Int16 PCM samples. Returns VAD probabilities for each completed
    /// 512-sample chunk (typically 0 or 1 per 20ms frame).
    public func feedSamples48kHz(_ samples: [Int16]) -> [Float] {
        // Downsample 48kHz → 16kHz (3:1 decimation)
        for i in stride(from: 0, to: samples.count, by: 3) {
            resampleBuffer.append(Float(samples[i]) / 32768.0)
        }

        var probs: [Float] = []
        while resampleBuffer.count >= Self.chunkSize {
            let chunk = Array(resampleBuffer.prefix(Self.chunkSize))
            resampleBuffer.removeFirst(Self.chunkSize)
            if let p = try? infer(chunk) {
                probs.append(p)
            }
        }
        return probs
    }

    /// Run inference on exactly 512 float32 samples at 16kHz. Returns speech probability [0, 1].
    public func infer(_ samples: [Float]) throws -> Float {
        precondition(samples.count == Self.chunkSize)

        // Prepend context window (64 samples) to input chunk (512 samples) → 576 total
        var inputWithContext = contextBuffer + samples
        // Save last 64 samples as context for next call
        contextBuffer = Array(inputWithContext.suffix(Self.contextSize))

        let totalSize = Self.contextSize + Self.chunkSize
        let inputData = NSMutableData(bytes: &inputWithContext, length: totalSize * MemoryLayout<Float>.size)
        let inputTensor = try ORTValue(
            tensorData: inputData, elementType: .float,
            shape: [1, NSNumber(value: totalSize)]
        )
        let stateTensor = try ORTValue(
            tensorData: stateData, elementType: .float, shape: [2, 1, 128]
        )
        let srTensor = try ORTValue(
            tensorData: srData, elementType: .int64, shape: []
        )

        let results = try model.session.run(
            withInputs: ["input": inputTensor, "state": stateTensor, "sr": srTensor],
            outputNames: ["output", "stateN"],
            runOptions: nil
        )

        let prob = try results["output"]!.tensorData().bytes.load(as: Float.self)

        // Update LSTM state
        let newState = try results["stateN"]!.tensorData()
        stateData.replaceBytes(
            in: NSRange(location: 0, length: stateData.length),
            withBytes: newState.bytes
        )

        return prob
    }
}
