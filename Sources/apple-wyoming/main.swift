// Wyoming speech-to-text server backed by Apple's on-device SpeechAnalyzer (macOS 26+).
// Audio arrives over the network (satellite -> Home Assistant -> here): the host microphone is never used.
import AVFoundation
import Foundation
import Speech

let version = "0.1.0"

/// Bounds on what an unauthenticated LAN client may send or hold open.
enum Limits {
    static let headerLine = 64 * 1024        // bytes in one JSON header line
    static let dataLength = 64 * 1024        // bytes of JSON data per event
    static let payloadLength = 1 << 20       // bytes of audio per chunk
    static let connections = 32              // open connections at once
    static let idleSeconds = 30              // a connection silent this long is dropped
    static let rates = 8_000...96_000
    static let channels = 1...8
}

// MARK: - Configuration

struct Config: Sendable {
    var host = "0.0.0.0"
    var port: UInt16 = 10300
    var engine = "dictation"            // dictation (DictationTranscriber) | speech (SpeechTranscriber)
    var locale = Locale(identifier: "fr-FR")

    static let usage = """
        usage: apple-wyoming [--host ADDR] [--port N] [--engine dictation|speech] [--locale ID]
          --host    IPv4 address to listen on (default 0.0.0.0)
          --port    TCP port (default 10300)
          --engine  dictation: Apple's dictation model, punctuation and digits (default)
                    speech:    SpeechTranscriber, the general transcription model (better on long monologues)
          --locale  language, e.g. fr-FR, en-US (default fr-FR)
          --version print the version
        """

    static func parse(_ args: [String]) -> Config {
        var c = Config()
        var it = args.dropFirst().makeIterator()
        func value(_ flag: String) -> String {
            guard let v = it.next() else { fail("\(flag) needs a value") }
            return v
        }
        while let a = it.next() {
            switch a {
            case "--host": c.host = value(a)
            case "--port":
                guard let p = UInt16(value(a)), p > 0 else { fail("--port must be 1-65535") }
                c.port = p
            case "--engine":
                c.engine = value(a)
                guard ["dictation", "speech"].contains(c.engine) else { fail("--engine must be dictation or speech") }
            case "--locale": c.locale = Locale(identifier: value(a))
            case "--version": print(version); exit(0)
            case "-h", "--help": print(usage); exit(0)
            default: fail("unknown argument \(a)")
            }
        }
        return c
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("apple-wyoming: \(message)\n\(Config.usage)\n".data(using: .utf8)!)
    exit(2)
}

// DateFormatter is thread-safe on macOS; one shared instance instead of one per line.
let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func log(_ s: String) {
    FileHandle.standardError.write("\(logFormatter.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

// MARK: - Transcription

/// One transcriber module and the way to read its text, whichever engine is used.
struct Job {
    let module: any SpeechModule
    let collect: @Sendable () async throws -> String
}

func makeJob(_ config: Config) -> Job {
    if config.engine == "dictation" {
        let t = DictationTranscriber(locale: config.locale, contentHints: [.shortForm, .farField],
                                     transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [])
        // Without volatileResults every result is a settled segment; dictation does not mark them isFinal,
        // so all of them are joined (keeping only the last would drop the start of a long utterance).
        return Job(module: t) {
            var parts: [String] = []
            for try await r in t.results {
                let p = String(r.text.characters).trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { parts.append(p) }
            }
            return parts.joined(separator: " ")
        }
    }
    let t = SpeechTranscriber(locale: config.locale, preset: .transcription)
    return Job(module: t) {
        var s = ""
        for try await r in t.results where r.isFinal { s += String(r.text.characters) }
        return s
    }
}

// MARK: - Wyoming protocol

struct Event: @unchecked Sendable {
    let type: String
    let data: [String: Any]
    let payload: Data
}

/// Wyoming framing: one JSON header line, then `data_length` bytes of JSON and `payload_length` bytes of payload.
/// Reading happens on the connection's own thread; writing on its handler task.
final class Socket: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()
    private var scanned = 0     // bytes of `buffer` already searched for a newline

    init(fd: Int32) { self.fd = fd }

    /// Blocking read; false at end of stream, on error, or after `Limits.idleSeconds` of silence (SO_RCVTIMEO).
    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); return true }
            if n < 0 && errno == EINTR { continue }
            return false
        }
    }

    private func take(_ n: Int) -> Data? {
        while buffer.count < n { if !fill() { return nil } }
        let d = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        scanned = 0
        return d
    }

    private func line() -> Data? {
        while true {
            if let i = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let l = Data(buffer[buffer.startIndex..<i])
                buffer = Data(buffer[buffer.index(after: i)...])
                scanned = 0
                return l
            }
            scanned = buffer.count
            guard buffer.count <= Limits.headerLine else { log("header line over \(Limits.headerLine) bytes, closing"); return nil }
            if !fill() { return nil }
        }
    }

    private static func length(_ header: [String: Any], _ key: String, max: Int) -> Int? {
        guard let v = header[key] else { return 0 }
        guard let n = v as? Int, (0...max).contains(n) else { log("invalid \(key) \(v), closing"); return nil }
        return n
    }

    func event() -> Event? {
        guard let l = line(), let header = (try? JSONSerialization.jsonObject(with: l)) as? [String: Any],
              let type = header["type"] as? String,
              let dataLength = Socket.length(header, "data_length", max: Limits.dataLength),
              let payloadLength = Socket.length(header, "payload_length", max: Limits.payloadLength)
        else { return nil }
        var data = (header["data"] as? [String: Any]) ?? [:]
        if dataLength > 0 {
            guard let d = take(dataLength) else { return nil }
            if let extra = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { data.merge(extra) { $1 } }
        }
        var payload = Data()
        if payloadLength > 0 {
            guard let p = take(payloadLength) else { return nil }
            payload = p
        }
        return Event(type: type, data: data, payload: payload)
    }

    func send(_ type: String, _ data: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: data),
              var out = try? JSONSerialization.data(withJSONObject: ["type": type, "data_length": body.count] as [String: Any])
        else { return }
        out.append(0x0A)
        out.append(body)
        out.withUnsafeBytes { p in
            var off = 0
            while off < out.count {
                let n = write(fd, p.baseAddress! + off, out.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }     // peer gone: SIGPIPE is ignored, the transcript is simply lost
                off += n
            }
        }
    }
}

func info(_ config: Config) -> [String: Any] {
    let attribution: [String: Any] = ["name": "Apple", "url": "https://developer.apple.com/documentation/speech/speechanalyzer"]
    let lang = config.locale.language.languageCode?.identifier ?? config.locale.identifier
    return ["asr": [[
        "name": "apple-\(config.engine)", "description": "Apple SpeechAnalyzer (\(config.engine))",
        "attribution": attribution, "installed": true, "version": version, "supports_transcript_streaming": false,
        "models": [["name": "\(config.engine)-\(config.locale.identifier)",
                    "description": "Apple \(config.engine) \(config.locale.identifier)",
                    "attribution": attribution, "installed": true, "version": version, "languages": [lang]]],
    ]]]
}

// MARK: - One utterance

/// Everything one audio-start ... audio-stop needs, torn down as a unit.
final class Utterance {
    let source: AVAudioFormat
    let target: AVAudioFormat
    let converter: AVAudioConverter?
    let input: AsyncStream<AnalyzerInput>.Continuation
    let analyzer: SpeechAnalyzer
    let collector: Task<String, Error>
    let started = Date()
    private var carry = Data()      // bytes of a frame split across two chunks

    init?(rate: Int, channels: Int, config: Config) async {
        guard let src = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate),
                                      channels: AVAudioChannelCount(channels), interleaved: true) else { return nil }
        let job = makeJob(config)
        let dst = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [job.module], considering: src) ?? src
        if dst != src {
            guard let conv = AVAudioConverter(from: src, to: dst) else { log("no converter from \(src) to \(dst)"); return nil }
            conv.downmix = true     // otherwise only the first channel of a stereo stream is kept
            converter = conv
        } else {
            converter = nil
        }
        source = src
        target = dst
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        analyzer = SpeechAnalyzer(modules: [job.module])
        collector = Task { try await job.collect() }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            log("analyzer start failed: \(error)")
            await cancel()
            return nil
        }
    }

    func feed(_ bytes: Data) {
        carry.append(bytes)
        let frameBytes = Int(source.streamDescription.pointee.mBytesPerFrame)
        let frames = carry.count / frameBytes
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        carry.withUnsafeBytes { _ = memcpy(pcm.int16ChannelData![0], $0.baseAddress!, frames * frameBytes) }
        carry = Data(carry.dropFirst(frames * frameBytes))
        guard let converter else { input.yield(AnalyzerInput(buffer: pcm)); return }
        var fed = false
        convert(converter, frames: frames) { status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
    }

    /// Ends the input (flushing the resampler's tail), lets the model finish and returns the text.
    func finish() async -> String {
        if let converter { convert(converter, frames: 0) { $0.pointee = .endOfStream; return nil } }
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log("transcription failed: \(error)")
            await cancel()
            return ""
        }
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        collector.cancel()
    }

    private func convert(_ converter: AVAudioConverter, frames: Int, _ block: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) {
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / source.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in block(status) }
        if let error { log("audio conversion failed: \(error)"); return }
        if out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }
}

// MARK: - One connection

/// One connection carries one utterance: describe?, transcribe?, audio-start, audio-chunk..., audio-stop -> transcript.
/// Any failure after audio-start still answers with a (possibly empty) transcript so the pipeline never hangs.
func handle(_ events: AsyncStream<Event>, _ sock: Socket, _ config: Config) async {
    var utterance: Utterance?
    for await ev in events {
        switch ev.type {
        case "describe":
            sock.send("info", info(config))

        case "audio-start":
            if let previous = utterance { await previous.cancel(); utterance = nil }
            let rate = ev.data["rate"] as? Int ?? 16000
            let channels = ev.data["channels"] as? Int ?? 1
            let width = ev.data["width"] as? Int ?? 2
            guard width == 2, Limits.rates.contains(rate), Limits.channels.contains(channels) else {
                log("unsupported audio rate=\(rate) width=\(width) channels=\(channels)")
                sock.send("transcript", ["text": ""])
                return
            }
            utterance = await Utterance(rate: rate, channels: channels, config: config)
            if utterance == nil { sock.send("transcript", ["text": ""]); return }

        case "audio-chunk":
            utterance?.feed(ev.payload)

        case "audio-stop":
            guard let u = utterance else { sock.send("transcript", ["text": ""]); return }
            let stopped = Date()
            let text = await u.finish()
            utterance = nil
            sock.send("transcript", ["text": text])
            log(String(format: "transcribed in %.0f ms after end of audio (%.1f s total): %@",
                       Date().timeIntervalSince(stopped) * 1000, Date().timeIntervalSince(u.started), text))
            return

        default:
            break   // transcribe, ping, etc.
        }
    }
    // The client went away (or idled out) mid-utterance.
    if let u = utterance { await u.cancel() }
}

/// Reads on a dedicated thread (blocking I/O must stay off Swift's cooperative pool, or a few idle clients would
/// starve every other connection), handles on a task, and closes the socket only once both are done.
final class ConnectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var open = 0
    func enter() -> Bool { lock.withLock { guard open < Limits.connections else { return false }; open += 1; return true } }
    func leave() { lock.withLock { open -= 1 } }
}

let connections = ConnectionCounter()

func serve(_ fd: Int32, _ config: Config) {
    guard connections.enter() else { log("too many connections, refusing one"); close(fd); return }
    var on: Int32 = 1
    let size = socklen_t(MemoryLayout<Int32>.size)
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, size)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, size)
    var keepIdle = Int32(Limits.idleSeconds)
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, size)
    var timeout = timeval(tv_sec: Limits.idleSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let sock = Socket(fd: fd)
    let (events, continuation) = AsyncStream.makeStream(of: Event.self)
    let handled = DispatchSemaphore(value: 0)
    let reader = Thread {
        while let ev = sock.event() { continuation.yield(ev) }
        continuation.finish()
        handled.wait()
        close(fd)
        connections.leave()
    }
    reader.stackSize = 1 << 20
    reader.start()
    Task.detached {
        await handle(events, sock, config)
        shutdown(fd, SHUT_RDWR)     // wakes the reader if it is still blocked in read()
        handled.signal()
    }
}

// MARK: - Startup

signal(SIGPIPE, SIG_IGN)
let config = Config.parse(CommandLine.arguments)
log("apple-wyoming \(version): engine \(config.engine), locale \(config.locale.identifier)")

do {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeJob(config).module]) {
        log("downloading the \(config.locale.identifier) speech model…")
        try await request.downloadAndInstall()
    }
    log("speech model ready")
} catch {
    log("speech model unavailable for \(config.locale.identifier): \(error)")
    exit(1)
}

let listener = socket(AF_INET, SOCK_STREAM, 0)
var reuse: Int32 = 1
setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_in()
address.sin_family = sa_family_t(AF_INET)
address.sin_port = config.port.bigEndian
guard inet_pton(AF_INET, config.host, &address.sin_addr) == 1 else { fail("--host must be an IPv4 address") }
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
guard bound == 0, listen(listener, 16) == 0 else {
    log("cannot listen on \(config.host):\(config.port): \(String(cString: strerror(errno)))")
    exit(1)
}
log("listening on \(config.host):\(config.port)")

let acceptor = Thread {
    while true {
        let fd = accept(listener, nil, nil)
        if fd >= 0 { serve(fd, config); continue }
        if errno != EINTR { usleep(100_000) }   // e.g. EMFILE: back off instead of spinning
    }
}
acceptor.start()
while true { try await Task.sleep(for: .seconds(3600)) }
