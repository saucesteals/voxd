import Foundation

// MARK: - CLI

struct Config {
    var socketPath = "/tmp/voxd.sock"
    var modelPath: String?
    var startThreshold: Float = 0.40
    var endThreshold: Float = 0.30
    var minSpeechMs: Int = 120
    var minSilenceMs: Int = 250
    var preRollMs: Int = 300
    var logVAD = false

    static func parse(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Config {
        var cfg = Config()
        var args = arguments

        if args.contains("-h") || args.contains("--help") {
            printUsage()
            exit(0)
        }

        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let val = args[i + 1]
            args.removeSubrange(i...i+1)
            return val
        }

        func takeFlag(_ flag: String) -> Bool {
            guard let i = args.firstIndex(of: flag) else { return false }
            args.remove(at: i)
            return true
        }

        if let v = take("--socket")          { cfg.socketPath = v }
        if let v = take("--model")           { cfg.modelPath = v }
        if let v = take("--start-threshold") { cfg.startThreshold = Float(v) ?? cfg.startThreshold }
        if let v = take("--end-threshold")   { cfg.endThreshold = Float(v) ?? cfg.endThreshold }
        if let v = take("--min-speech")      { cfg.minSpeechMs = Int(v) ?? cfg.minSpeechMs }
        if let v = take("--min-silence")     { cfg.minSilenceMs = Int(v) ?? cfg.minSilenceMs }
        if let v = take("--pre-roll")        { cfg.preRollMs = Int(v) ?? cfg.preRollMs }
        if takeFlag("--log-vad")             { cfg.logVAD = true }

        // Positional: first non-flag arg is socket path
        if let positional = args.first, !positional.hasPrefix("-") {
            cfg.socketPath = positional
        }

        // Auto-discover model if not specified
        if cfg.modelPath == nil {
            cfg.modelPath = findModel("silero_vad.onnx")
        }

        return cfg
    }

    private static func findModel(_ name: String) -> String? {
        // Next to executable
        let execDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let beside = (execDir as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: beside) { return beside }

        // Working directory
        let cwd = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: cwd) { return cwd }

        // ~/models/vad/
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let shared = "\(home)/models/vad/\(name)"
            if FileManager.default.fileExists(atPath: shared) { return shared }
        }

        return nil
    }

    private static func printUsage() {
        print("""
        voxd - low-latency voice activity detection sidecar

        USAGE:
          voxd [options] [socket-path]

        OPTIONS:
          --socket <path>          Unix socket path (default: /tmp/voxd.sock)
          --model <path>           Path to silero_vad.onnx
          --start-threshold <f>    Speech start threshold 0.0-1.0 (default: 0.40)
          --end-threshold <f>      Speech end threshold 0.0-1.0 (default: 0.30)
          --min-speech <ms>        Min speech duration in ms (default: 120)
          --min-silence <ms>       Min silence duration in ms (default: 250)
          --pre-roll <ms>          Pre-roll buffer in ms (default: 300)
          --log-vad                Log VAD probabilities to stderr
          -h, --help               Show this help

        MODEL DISCOVERY:
          If --model is not specified, voxd looks for silero_vad.onnx in:
            1. Next to the voxd binary
            2. Current working directory
            3. ~/models/vad/
          If no model is found, voxd falls back to RMS energy detection.
        """)
    }
}

// MARK: - Entry point

let cfg = Config.parse()

fputs("voxd starting\n", stderr)
fputs("  socket: \(cfg.socketPath)\n", stderr)
fputs("  model:  \(cfg.modelPath ?? "none (RMS fallback)")\n", stderr)
fputs("  vad:    start=\(cfg.startThreshold) end=\(cfg.endThreshold) speech=\(cfg.minSpeechMs)ms silence=\(cfg.minSilenceMs)ms preroll=\(cfg.preRollMs)ms\n", stderr)

let gateConfig = GateConfig(
    startThreshold: cfg.startThreshold,
    endThreshold: cfg.endThreshold,
    minSpeechMs: cfg.minSpeechMs,
    minSilenceMs: cfg.minSilenceMs,
    preRollMs: cfg.preRollMs,
    logVAD: cfg.logVAD
)

let server = IPCServer(socketPath: cfg.socketPath, modelPath: cfg.modelPath, gateConfig: gateConfig)
do {
    try server.start()
} catch {
    fputs("fatal: \(error)\n", stderr)
    exit(1)
}

dispatchMain()
