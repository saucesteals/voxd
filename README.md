<p align="center">
  <img src="assets/banner.png" alt="voxd" width="100%">
</p>

<h1 align="center">voxd</h1>
<p align="center">Low-latency voice activity detection sidecar for real-time audio pipelines.</p>

---

voxd sits between your audio source and speech processing pipeline. It accepts raw PCM audio over a Unix socket, runs it through [Silero VAD](https://github.com/snakers4/silero-vad), and emits speech boundary events — so your pipeline only processes audio when someone is actually talking.

## Features

- **Silero VAD v5** — neural speech detection via ONNX Runtime
- **Unix socket IPC** — binary framing protocol for zero-copy integration with any language
- **Shared model** — single ONNX session serves multiple concurrent connections with isolated LSTM state
- **Tunable gating** — thresholds, durations, and pre-roll configurable via CLI flags
- **Pre-roll buffer** — captures audio before speech is confirmed so utterances aren't clipped

## Build

```
swift build -c release
```

## Usage

```
voxd [options] [socket-path]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--socket <path>` | `/tmp/voxd.sock` | Unix socket path |
| `--model <path>` | auto-discover | Path to `silero_vad.onnx` |
| `--start-threshold <f>` | `0.40` | VAD probability to start speech |
| `--end-threshold <f>` | `0.30` | VAD probability to end speech |
| `--min-speech <ms>` | `120` | Min speech duration before emitting |
| `--min-silence <ms>` | `250` | Min silence duration before ending |
| `--pre-roll <ms>` | `300` | Audio buffered before speech detection |
| `--log-vad` | off | Log VAD probabilities to stderr |

### Model discovery

If `--model` isn't set, voxd looks for `silero_vad.onnx` in:

1. Next to the `voxd` binary
2. Current working directory
3. `~/models/vad/`

If no model is found, voxd exits with an error.

### Examples

```bash
# Auto-discover model, default socket
voxd

# Explicit everything
voxd --socket /tmp/voice.sock --model ~/models/vad/silero_vad.onnx

# Noisy environment
voxd --start-threshold 0.6 --end-threshold 0.4 --min-silence 400

# Debug
voxd --log-vad
```

## Wire protocol

Unix stream socket, length-prefixed binary frames.

### Frame format

```
[u32 length] [28-byte header] [payload]
```

**Header** (big-endian):

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | Message type |
| 1 | 1 | Flags (reserved) |
| 2 | 2 | Header length |
| 4 | 8 | Stream ID |
| 12 | 8 | Sequence number |
| 20 | 8 | Timestamp (ms) |

### Messages

| Type | Hex | Direction | Payload |
|------|-----|-----------|---------|
| `IN_AUDIO` | `0x20` | client → voxd | 48kHz PCM16LE |
| `OUT_AUDIO` | `0x21` | voxd → client | Gated PCM16LE |
| `SPEECH_START` | `0x30` | voxd → client | empty |
| `SPEECH_END` | `0x31` | voxd → client | empty |

### Flow

1. Connect to Unix socket
2. Send `IN_AUDIO` frames (20ms @ 48kHz = 960 samples = 1920 bytes)
3. voxd replies with `SPEECH_START` → `OUT_AUDIO` stream → `SPEECH_END`
4. Pre-roll audio from before the trigger is included

## Architecture

```
┌──────────┐     IN_AUDIO      ┌─────────────────────────────┐
│  Client  │ ──────────────▶   │           voxd              │
│          │                   │                             │
│          │ ◀──────────────   │  48kHz → 16kHz resampler    │
│          │  SPEECH_START     │         ↓                   │
│          │  OUT_AUDIO        │  Silero VAD (ONNX Runtime)  │
│          │  SPEECH_END       │         ↓                   │
└──────────┘                   │  Gate state machine         │
                               │         ↓                   │
                               │  Pre-roll buffer            │
                               └─────────────────────────────┘
```

Each connection gets its own VAD stream and gate state. The ONNX model is loaded once and shared.

## Tests

```
swift test
```

Requires `silero_vad.onnx` at `~/models/vad/` or `VOXD_MODEL_PATH`.

## License

MIT
