import Foundation

/// A pretend car: a repeating drive cycle with a cold start, so values move plausibly.
public struct SimulatedCar: Sendable {
    public var ambientC = 15.0
    public var baroKPa = 84.0
    public var ignitionOn = true
    public var engineRunning = true
    /// Adds a slow coolant climb well past normal, for testing alerts.
    public var overheat = false
    public var startFuelPct = 62.0

    public init() {}

    struct State {
        var speed = 0.0, rpm = 0.0, throttle = 0.0, pedal = 0.0, maf = 0.0, map = 0.0, load = 0.0
        var coolant = 0.0, oil = 0.0, cvt = 0.0, intake = 0.0, turbine = 0.0, lockup = 0.0
        var fuelPct = 0.0, voltage = 0.0, stft = 0.0, ltft = 2.3, lambda = 1.0, catTemp = 0.0, runTime = 0.0
    }

    func state(at t: Double) -> State {
        var s = State()
        let cycle = t.truncatingRemainder(dividingBy: 300)
        func ramp(_ a: Double, _ b: Double) -> Double { Swift.min(1, Swift.max(0, (cycle - a) / (b - a))) }
        var accel = 0.0
        if !engineRunning || cycle < 30 || cycle >= 240 {
            s.speed = 0
        } else if cycle < 60 {
            s.speed = 75 * ramp(30, 60); accel = 1
        } else if cycle < 200 {
            s.speed = 85 + 15 * sin((cycle - 60) / 14)
        } else {
            s.speed = 85 * (1 - ramp(200, 240)); accel = -1
        }
        let wiggle = sin(t * 1.7) * 0.5 + sin(t * 0.37)
        s.rpm = engineRunning ? (s.speed < 1 ? 700 + wiggle * 8 : 1150 + s.speed * 14 + accel * 600 + wiggle * 20) : 0
        s.throttle = engineRunning ? (accel > 0 ? 32 : accel < 0 ? 0 : (s.speed > 1 ? 17 + wiggle : 0)) + 14.5 : 0
        s.pedal = Swift.max(0, (s.throttle - 14.5) * 1.2)
        s.load = engineRunning ? (accel > 0 ? 70 : accel < 0 ? 12 : (s.speed > 1 ? 38 : 22)) + wiggle : 0
        s.maf = engineRunning ? s.rpm / 1000 * (1.2 + s.load / 25) : 0
        s.map = engineRunning ? 25 + s.load * 0.75 : baroKPa
        let warm = 1 - exp(-t / 420)
        s.coolant = ambientC + (89 - ambientC) * warm + (t > 900 ? 2.5 * sin(t / 60) : 0) + (overheat ? t / 30 : 0)
        s.oil = ambientC + (96 - ambientC) * (1 - exp(-t / 900))
        s.cvt = ambientC + (78 - ambientC) * (1 - exp(-t / 1300))
        s.intake = ambientC + 8 + (s.speed < 5 ? 10 * warm : 0)
        s.lockup = s.speed > 40 && accel == 0 ? 99.5 : (s.speed > 20 ? 43.5 : 0)
        s.turbine = s.speed < 1 ? s.rpm * 0.94 : s.rpm * (s.lockup > 90 ? 1.0 : 0.93)
        s.fuelPct = startFuelPct - t / 600
        s.voltage = engineRunning ? 14.1 + wiggle * 0.05 : 12.4
        s.stft = sin(t * 2.3) * 3
        s.lambda = 1 + sin(t * 3.1) * 0.02
        s.catTemp = engineRunning ? 300 + 350 * warm + s.load * 1.5 : ambientC
        s.runTime = engineRunning ? t : 0
        return s
    }

    static func u16(_ v: Double) -> [UInt8] {
        let x = UInt16(Swift.max(0, Swift.min(65535, v.rounded())))
        return [UInt8(x >> 8), UInt8(x & 0xFF)]
    }
    static func u8(_ v: Double) -> UInt8 { UInt8(Swift.max(0, Swift.min(255, v.rounded()))) }
    static func pct(_ v: Double) -> UInt8 { u8(v * 255 / 100) }
    static func temp(_ c: Double) -> UInt8 { u8(c + 40) }
    static func trim(_ v: Double) -> UInt8 { u8(v * 128 / 100 + 128) }

    /// Bitmaps as reported by the 2010 Outback's engine (7E8) and transmission (7E9) computers.
    static let bitmaps: [UInt16: [UInt8: [UInt8]]] = [
        0x7E8: [0x00: [0xBE, 0x3F, 0xA8, 0x13], 0x20: [0x90, 0x1F, 0xF0, 0x11], 0x40: [0xFE, 0xDC, 0x80, 0x41], 0x60: [0x08, 0x00, 0x00, 0x00]],
        0x7E9: [0x00: [0x80, 0x00, 0x00, 0x01], 0x20: [0x80, 0x00, 0x00, 0x00]],
    ]

    func mode01(_ responder: UInt16, _ pid: UInt8, t: Double) -> [UInt8]? {
        if let maps = Self.bitmaps[responder], StandardPIDs.isSupportBitmap(pid) { return maps[pid] }
        let supported = Self.bitmaps[responder].map { maps in
            maps.reduce(into: Set<UInt8>()) { $0.formUnion(StandardPIDs.supported(base: $1.key, bitmap: $1.value)) }
        } ?? []
        guard supported.contains(pid) else { return nil }
        if responder == 0x7E9 { return pid == 0x01 ? [0, 0x07, 0xE5, 0x00] : [0, 0] }
        let s = state(at: t)
        switch pid {
        case 0x01: return [0x00, 0x07, 0x65, 0x00]
        case 0x03: return [s.coolant > 40 ? 2 : 1, 0]
        case 0x04: return [Self.pct(s.load)]
        case 0x05: return [Self.temp(s.coolant)]
        case 0x06: return [Self.trim(s.stft)]
        case 0x07: return [Self.trim(s.ltft)]
        case 0x0B: return [Self.u8(s.map)]
        case 0x0C: return Self.u16(s.rpm * 4)
        case 0x0D: return [Self.u8(s.speed)]
        case 0x0E: return [Self.u8((12 + s.load / 10 + 64) * 2)]
        case 0x0F: return [Self.temp(s.intake)]
        case 0x10: return Self.u16(s.maf * 100)
        case 0x11: return [Self.pct(s.throttle)]
        case 0x13: return [0x03]
        case 0x15: return [Self.u8(0.65 * 200), 0xFF]
        case 0x1C: return [0x01]
        case 0x1F: return Self.u16(s.runTime)
        case 0x21: return [0, 0]
        case 0x24: return Self.u16(s.lambda * 32768) + Self.u16(3.3 * 8192)
        case 0x2C: return [Self.pct(s.speed > 50 ? 40 : 0)]
        case 0x2D: return [0x80]
        case 0x2E: return [Self.pct(s.coolant > 60 ? 25 : 0)]
        case 0x2F: return [Self.pct(s.fuelPct)]
        case 0x30: return [0xFF]
        case 0x31: return Self.u16(4321)
        case 0x32: return Self.u16(65536 - 120 * 4)
        case 0x33: return [Self.u8(baroKPa)]
        case 0x34: return Self.u16(s.lambda * 32768) + Self.u16((128 + (1 - s.lambda) * 5) * 256)
        case 0x3C: return Self.u16((s.catTemp + 40) * 10)
        case 0x41: return [0x00, 0x07, 0x65, 0x00]
        case 0x42: return Self.u16(s.voltage * 1000)
        case 0x43: return Self.u16(s.load * 255 / 100)
        case 0x44: return Self.u16(32768)
        case 0x45: return [Self.pct(Swift.max(0, s.throttle - 14.5))]
        case 0x46: return [Self.temp(ambientC)]
        case 0x47: return [Self.pct(s.throttle + 2)]
        case 0x49: return [Self.pct(s.pedal + 15)]
        case 0x4A: return [Self.pct(s.pedal / 2 + 7.5)]
        case 0x4C: return [Self.pct(s.throttle - 1)]
        case 0x4D, 0x4E: return [0, 0]
        case 0x51: return [0x01]
        case 0x5A: return [Self.pct(s.pedal)]
        case 0x65: return [0x00, 0x00]
        default: return nil
        }
    }

    func ssm(_ module: UInt16, _ address: UInt32, t: Double) -> UInt8? {
        let s = state(at: t)
        switch (module, address) {
        case (0x7E0, 0x000113): return Self.temp(s.oil)
        case (0x7E0, 0x0000F9): return 3
        case (0x7E1, 0x000056): return Self.temp(s.cvt)
        case (0x7E1, 0x00004F): return Self.u8(s.turbine / 32)
        case (0x7E1, 0x00004C): return Self.u8(s.lockup * 2)
        case (0x7E1, 0x00004D): return Self.u8(s.speed > 1 ? 30 : 0)
        case (0x7E1, 0x000048), (0x7E1, 0x000294), (0x7E1, 0x000295): return Self.u8(s.speed)
        case (0x7E1, 0x000051), (0x7E1, 0x000296): return 0
        case (0x7E1, 0x000293): return 128
        default: return nil
        }
    }
}

/// Behaves like the Veepeak (ELM327 v2.2 clone) on a CAN Subaru, for tests and demo mode.
public final class SimulatedAdapter: OBDTransport, @unchecked Sendable {
    public var car: SimulatedCar
    /// Seconds from request to reply.
    public var latency: Double
    /// Bytes per notification, like a BLE MTU.
    public var chunkSize = 20

    private let lock = NSLock()
    private var handler: (@Sendable ([UInt8]) -> Void)?
    private var pending: [UInt8] = []
    private var connected = true
    private var echo = true
    private var headers = false
    private var header: UInt16 = 0x7DF
    private var receiveFilter: UInt16?
    private let started = Date()
    private var timeOffset: Double
    public private(set) var received: [String] = []

    public init(car: SimulatedCar = SimulatedCar(), latency: Double = 0.05, startAt seconds: Double = 0) {
        self.car = car
        self.latency = latency
        self.timeOffset = seconds
    }

    public var isConnected: Bool { lock.locked { connected } }

    public func setReceiveHandler(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        lock.locked { self.handler = handler }
    }

    public func setConnected(_ on: Bool) { lock.locked { connected = on } }

    public func setIgnition(on: Bool, engineRunning: Bool) {
        lock.locked {
            car.ignitionOn = on
            car.engineRunning = engineRunning && on
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        let commands: [String]? = lock.locked {
            guard connected else { return nil }
            pending += bytes
            var cmds: [String] = []
            while let i = pending.firstIndex(of: 0x0D) {
                cmds.append(String(decoding: pending[..<i], as: UTF8.self).uppercased().replacingOccurrences(of: " ", with: ""))
                pending.removeSubrange(...i)
            }
            return cmds
        }
        guard let commands else { throw OBDError.disconnected }
        for cmd in commands {
            let reply = respond(cmd)
            let delay = latency
            Task { [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                self?.deliver(reply)
            }
        }
    }

    private func deliver(_ text: String) {
        let (h, ok) = lock.locked { (handler, connected) }
        guard ok, let h else { return }
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            h(Array(bytes[i..<min(bytes.count, i + chunkSize)]))
            i += chunkSize
        }
    }

    private func respond(_ cmd: String) -> String {
        let (body, echoNow) = lock.locked { () -> (String, Bool) in
            received.append(cmd)
            if received.count > 2000 { received.removeFirst(1000) }
            let e = echo
            return (handle(cmd), e)
        }
        return (echoNow ? cmd + "\r" : "") + body + "\r\r>"
    }

    /// Called with the lock held.
    private func handle(_ cmd: String) -> String {
        if cmd.hasPrefix("AT") || cmd.hasPrefix("ST") {
            switch cmd {
            case "ATZ":
                echo = true; headers = false; header = 0x7DF; receiveFilter = nil
                return "\rELM327 v2.2"
            case "ATE0": echo = false; return "OK"
            case "ATH1": headers = true; return "OK"
            case "ATI": return "ELM327 v2.2"
            case "AT@1": return "OBDII to RS232 Interpreter"
            case "STI", "STDI": return "?"
            case "ATRV": return String(format: "%.1fV", car.engineRunning ? 14.1 : 12.4)
            case "ATDP": return "AUTO, ISO 15765-4 (CAN 11/500)"
            case "ATDPN": return "A6"
            case "ATAR": receiveFilter = nil; return "OK"
            default:
                if cmd.hasPrefix("ATSH"), let h = UInt16(cmd.dropFirst(4), radix: 16) { header = h; return "OK" }
                if cmd.hasPrefix("ATCRA"), let f = UInt16(cmd.dropFirst(5), radix: 16) { receiveFilter = f; return "OK" }
                return "OK"
            }
        }
        guard car.ignitionOn, let req = Hex.bytes(cmd), let service = req.first else {
            return car.ignitionOn ? "?" : "NO DATA"
        }
        let t = Date().timeIntervalSince(started) + timeOffset
        let responders: [UInt16] = header == 0x7DF ? [0x7E8, 0x7E9] : [header + 8]
        var frames: [String] = []
        for r in responders where receiveFilter == nil || receiveFilter == r {
            guard let payload = answer(responder: r, service: service, request: req, t: t) else { continue }
            frames += encode(responder: r, payload: payload)
        }
        return frames.isEmpty ? "NO DATA" : frames.joined(separator: "\r")
    }

    private func answer(responder: UInt16, service: UInt8, request: [UInt8], t: Double) -> [UInt8]? {
        switch service {
        case 0x01:
            var out: [UInt8] = [0x41]
            for pid in request.dropFirst() {
                guard let data = car.mode01(responder, pid, t: t) else { continue }
                out += [pid] + data
            }
            return out.count > 1 ? out : nil
        case 0xA8:
            guard request.count == 5, responder == 0x7E8 || responder == 0x7E9 else { return nil }
            let address = UInt32(request[2]) << 16 | UInt32(request[3]) << 8 | UInt32(request[4])
            if let v = car.ssm(responder - 8, address, t: t) { return [0xE8, v] }
            return [0x7F, 0xA8, 0x13]
        case 0x03, 0x07, 0x0A:
            return responder == 0x7E8 ? [service + 0x40, 0x00] : nil
        default:
            return nil
        }
    }

    private func encode(responder: UInt16, payload: [UInt8]) -> [String] {
        let id = hex3(responder)
        if payload.count <= 7 { return [id + Hex.string([UInt8(payload.count)] + payload)] }
        var frames = [id + Hex.string([0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload.prefix(6))]
        var rest = Array(payload.dropFirst(6))
        var seq: UInt8 = 1
        while !rest.isEmpty {
            var chunk = Array(rest.prefix(7))
            rest = Array(rest.dropFirst(7))
            chunk += [UInt8](repeating: 0, count: 7 - chunk.count)
            frames.append(id + Hex.string([0x20 | seq] + chunk))
            seq = (seq + 1) & 0x0F
        }
        return frames
    }
}
