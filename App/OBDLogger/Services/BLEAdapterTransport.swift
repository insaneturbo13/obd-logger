import CoreBluetooth
import Foundation
import OBDKit

/// Bluetooth LE link to an ELM327-style adapter with a serial-like notify/write
/// characteristic pair (the Veepeak uses FFF0: notify FFF1, write FFF2).
///
/// Once an adapter has been found, its identifier is remembered and the app asks iOS for a
/// standing connection to it. iOS completes that connection whenever the adapter powers
/// up, even with the app in the background, which is what makes automatic trip
/// recording work.
final class BLEAdapterTransport: NSObject, OBDTransport, @unchecked Sendable {
    enum Event: Equatable {
        case poweredOff
        case unauthorized
        case searching
        case connecting(name: String)
        case ready(name: String, id: UUID)
        case disconnected(name: String)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    static let knownUART: [(service: String, notify: String, write: String)] = [
        ("FFF0", "FFF1", "FFF2"),
        ("FFE0", "FFE1", "FFE1"),
        ("18F0", "2AF0", "2AF1"),
        ("E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
    ]
    static let nameHints = ["VEEPEAK", "OBD", "VLINK", "V-LINK", "ELM", "IOS-VLINK"]
    static let restoreID = "obdlogger.central"

    private let queue = DispatchQueue(label: "obdlogger.ble")
    private let lock = NSLock()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private var handler: (@Sendable ([UInt8]) -> Void)?
    private var ready = false
    private var rememberedID: UUID?
    private var wantConnection = false
    private var pendingWrites: [Data] = []

    init(rememberedID: UUID?) {
        self.rememberedID = rememberedID
        super.init()
    }

    /// Creates the central (prompting for Bluetooth permission the first time) and starts connecting.
    func start() {
        lock.withLock { wantConnection = true }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue, options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ])
        } else {
            queue.async { self.connectOrScan() }
        }
    }

    /// Drops the link and forgets the adapter (to pick a different one).
    func forget() {
        queue.async {
            self.lock.withLock {
                self.rememberedID = nil
                self.wantConnection = false
            }
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.central?.stopScan()
        }
    }

    func stop() {
        queue.async {
            self.lock.withLock { self.wantConnection = false }
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.central?.stopScan()
        }
    }

    // MARK: OBDTransport

    var isConnected: Bool { lock.withLock { ready } }

    func setReceiveHandler(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func write(_ bytes: [UInt8]) async throws {
        guard isConnected else { throw OBDError.disconnected }
        let data = Data(bytes)
        queue.async {
            guard let p = self.peripheral, let c = self.writeChar, p.state == .connected else { return }
            let max = Swift.max(20, p.maximumWriteValueLength(for: self.writeType))
            var offset = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset..<Swift.min(data.count, offset + max))
                if self.writeType == .withoutResponse && !p.canSendWriteWithoutResponse {
                    self.pendingWrites.append(chunk)
                } else {
                    p.writeValue(chunk, for: c, type: self.writeType)
                }
                offset += max
            }
        }
    }

    // MARK: internals (on `queue`)

    private func emit(_ e: Event) { onEvent?(e) }

    private func connectOrScan() {
        guard central.state == .poweredOn, lock.withLock({ wantConnection }) else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        if let id = lock.withLock({ rememberedID }), let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
            return
        }
        emit(.searching)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        emit(.connecting(name: p.name ?? "adapter"))
        // No timeout: iOS keeps this pending until the adapter is in range and powered.
        central.connect(p, options: nil)
    }

    private func looksLikeAdapter(_ p: CBPeripheral, _ adv: [String: Any]) -> Bool {
        let name = ((adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "").uppercased()
        if Self.nameHints.contains(where: { name.contains($0) }) { return true }
        let services = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        return services.contains(CBUUID(string: "FFF0"))
    }

    private func pickCharacteristics(_ p: CBPeripheral) {
        let services = p.services ?? []
        var chosen: (CBCharacteristic, CBCharacteristic)?
        for known in Self.knownUART {
            guard let s = services.first(where: { $0.uuid == CBUUID(string: known.service) }) else { continue }
            let chars = s.characteristics ?? []
            if let n = chars.first(where: { $0.uuid == CBUUID(string: known.notify) && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }),
               let w = chars.first(where: { $0.uuid == CBUUID(string: known.write) && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }) {
                chosen = (n, w)
                break
            }
        }
        if chosen == nil {
            let standard = ["1800", "1801", "180A", "180F"].map { CBUUID(string: $0) }
            for s in services where !standard.contains(s.uuid) {
                let chars = s.characteristics ?? []
                if let n = chars.first(where: { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }),
                   let w = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) {
                    chosen = (n, w)
                    break
                }
            }
        }
        guard let (n, w) = chosen else {
            central.cancelPeripheralConnection(p)
            return
        }
        notifyChar = n
        writeChar = w
        writeType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.setNotifyValue(true, for: n)
    }

    private func linkLost(_ p: CBPeripheral) {
        let wasReady = lock.withLock { () -> Bool in
            let r = ready
            ready = false
            return r
        }
        pendingWrites.removeAll()
        if wasReady { emit(.disconnected(name: p.name ?? "adapter")) }
        // Ask again right away; iOS completes it when the adapter comes back.
        if lock.withLock({ wantConnection }), central.state == .poweredOn {
            connect(p)
        }
    }
}

extension BLEAdapterTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectOrScan()
        case .poweredOff:
            lock.withLock { ready = false }
            emit(.poweredOff)
        case .unauthorized:
            emit(.unauthorized)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched the app in the background for a Bluetooth event.
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = p
            p.delegate = self
            notifyChar = nil
            writeChar = nil
            if p.state == .connected { p.discoverServices(nil) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard looksLikeAdapter(p, advertisementData) else { return }
        central.stopScan()
        lock.withLock { rememberedID = p.identifier }
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        notifyChar = nil
        writeChar = nil
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        linkLost(p)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        linkLost(p)
    }
}

extension BLEAdapterTransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Pick once every service has its characteristics.
        guard notifyChar == nil, (p.services ?? []).allSatisfy({ $0.characteristics != nil }) else { return }
        pickCharacteristics(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c == notifyChar, c.isNotifying, error == nil else { return }
        lock.withLock { ready = true }
        emit(.ready(name: p.name ?? "adapter", id: p.identifier))
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let value = c.value, !value.isEmpty else { return }
        let h = lock.withLock { handler }
        h?(Array(value))
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        guard let c = writeChar else { return }
        while !pendingWrites.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(pendingWrites.removeFirst(), for: c, type: .withoutResponse)
        }
    }
}
