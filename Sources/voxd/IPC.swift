import Foundation

// MARK: - Wire protocol
//
// Each frame on the wire:
//   [u32 totalLen] [header] [payload]
//
// Header (28 bytes):
//   [u8 msgType] [u8 flags] [u16 headerLen] [u64 streamID] [u64 seq] [u64 timeMs]
//
// All multi-byte integers are big-endian.

let kHeaderSize = 28

// Message types
public let kMsgInAudio:     UInt8 = 0x20  // client → voxd: raw PCM audio
public let kMsgOutAudio:    UInt8 = 0x21  // voxd → client: gated PCM audio
public let kMsgSpeechStart: UInt8 = 0x30  // voxd → client: speech boundary
public let kMsgSpeechEnd:   UInt8 = 0x31  // voxd → client: speech boundary

// MARK: - Frame header

struct FrameHeader {
    var msgType: UInt8
    var flags: UInt8
    var headerLen: UInt16
    var streamID: UInt64
    var seq: UInt64
    var timeMs: UInt64

    static func parse(_ b: [UInt8], offset: Int = 0) -> FrameHeader? {
        guard b.count >= offset + kHeaderSize else { return nil }
        let i = offset

        func u16(_ j: Int) -> UInt16 { UInt16(b[j]) << 8 | UInt16(b[j + 1]) }
        func u64(_ j: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v = v << 8 | UInt64(b[j + k]) }
            return v
        }

        return FrameHeader(
            msgType: b[i], flags: b[i + 1], headerLen: u16(i + 2),
            streamID: u64(i + 4), seq: u64(i + 12), timeMs: u64(i + 20)
        )
    }
}

// MARK: - Server

/// Unix socket IPC server. Loads the VAD model once; each client connection
/// gets its own `AudioProcessor` with an independent VAD stream.
public class IPCServer {
    private let socketPath: String
    private let vadModel: SileroVADModel
    private let gateConfig: GateConfig

    public init(socketPath: String, modelPath: String, gateConfig: GateConfig = .default) throws {
        self.socketPath = socketPath
        self.gateConfig = gateConfig
        self.vadModel = try SileroVADModel(modelPath: modelPath)
        fputs("[vad] model loaded: \(modelPath)\n", stderr)
    }

    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno)!) }

        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in _ = strncpy(ptr, src, socketPath.utf8.count) }
        }

        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(fd); throw POSIXError(.init(rawValue: errno)!) }
        guard listen(fd, 5) == 0 else { close(fd); throw POSIXError(.init(rawValue: errno)!) }

        fputs("[ipc] listening on \(socketPath)\n", stderr)

        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let clientFd = accept(fd, nil, nil)
                guard clientFd >= 0 else { continue }
                fputs("[ipc] client connected fd=\(clientFd)\n", stderr)
                self.handleConnection(clientFd)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        let model = self.vadModel
        let config = self.gateConfig
        DispatchQueue.global(qos: .userInitiated).async {
            let conn = Connection(fd: fd, vadModel: model, gateConfig: config)

            conn.runReadLoop()
            fputs("[ipc] client disconnected fd=\(fd)\n", stderr)
        }
    }
}

// MARK: - Connection

/// A single client connection. Reads framed audio, runs it through an
/// `AudioProcessor`, and writes back speech events and gated audio.
class Connection {
    let fd: Int32
    private var buf = [UInt8]()
    private let processor: AudioProcessor
    private var outSeq: UInt64 = 0

    init(fd: Int32, vadModel: SileroVADModel, gateConfig: GateConfig = .default) {
        self.fd = fd
        self.processor = AudioProcessor(model: vadModel, config: gateConfig)
    }

    func runReadLoop() {
        let rbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { rbuf.deallocate(); close(fd) }

        while true {
            let n = recv(fd, rbuf, 65536, 0)
            if n <= 0 { return }
            buf.append(contentsOf: UnsafeBufferPointer(start: rbuf, count: n))
            drainFrames()
        }
    }

    private func drainFrames() {
        while buf.count >= 4 {
            let totalLen = Int(
                UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 |
                UInt32(buf[2]) << 8  | UInt32(buf[3])
            )
            guard buf.count >= 4 + totalLen else { return }

            guard let header = FrameHeader.parse(buf, offset: 4) else {
                buf.removeFirst(4 + totalLen)
                continue
            }

            let payloadStart = 4 + Int(header.headerLen)
            let payloadEnd   = 4 + totalLen
            let payload = payloadStart < payloadEnd ? Array(buf[payloadStart..<payloadEnd]) : []

            buf.removeFirst(4 + totalLen)

            if header.msgType == kMsgInAudio {
                let results = processor.processAudio(
                    samples: payload, streamID: header.streamID, timeMs: header.timeMs
                )
                for r in results {
                    sendFrame(msgType: r.msgType, streamID: header.streamID,
                              timeMs: r.timeMs, payload: r.payload)
                }
            }
        }
    }

    private func sendFrame(msgType: UInt8, streamID: UInt64, timeMs: UInt64, payload: [UInt8]) {
        outSeq += 1
        let bodyLen = kHeaderSize + payload.count
        var frame = [UInt8]()
        frame.reserveCapacity(4 + bodyLen)

        // Length prefix
        appendU32BE(&frame, UInt32(bodyLen))
        // Header
        frame.append(msgType)
        frame.append(0) // flags
        appendU16BE(&frame, UInt16(kHeaderSize))
        appendU64BE(&frame, streamID)
        appendU64BE(&frame, outSeq)
        appendU64BE(&frame, timeMs)
        // Payload
        frame.append(contentsOf: payload)

        frame.withUnsafeBytes { ptr in
            var sent = 0
            while sent < frame.count {
                let n = Darwin.send(fd, ptr.baseAddress! + sent, frame.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

// MARK: - Encoding helpers

private func appendU16BE(_ buf: inout [UInt8], _ v: UInt16) {
    buf.append(UInt8(v >> 8))
    buf.append(UInt8(v & 0xff))
}

private func appendU32BE(_ buf: inout [UInt8], _ v: UInt32) {
    buf.append(UInt8(v >> 24))
    buf.append(UInt8((v >> 16) & 0xff))
    buf.append(UInt8((v >> 8) & 0xff))
    buf.append(UInt8(v & 0xff))
}

private func appendU64BE(_ buf: inout [UInt8], _ v: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
        buf.append(UInt8((v >> shift) & 0xff))
    }
}
