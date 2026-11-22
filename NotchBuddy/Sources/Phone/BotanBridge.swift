import CoreBluetooth
import Foundation
import Observation
import UIKit

// MARK: - Botan on the iPhone: the bridge (docs/BOTAN_LINK.md)
//
// Botan is the little screen with one button on the back of the iPhone. The Mac publishes its
// sessions to iCloud (SessionPublisher); this bridge turns them into Botan's one line, and Botan's
// button into the same Decision / Answer records a tap in the app sends. So Botan works wherever the
// iPhone has the network, with the iPhone locked in a pocket.
//
// How a locked iPhone keeps up (UIBackgroundModes: bluetooth-central, remote-notification):
//   * iCloud's pushes wake the app (PhoneLink.handlePush): the new line is written to Botan then;
//   * Botan's events wake the app too (bluetooth-central): a press is sent to iCloud right away;
//   * Botan sends a heartbeat ("tick") every 15 s: when iCloud's quiet pushes are held back by iOS,
//     the tick wakes the app and it looks for news itself, so Botan is never more than a few seconds late;
//   * if iOS ends the app to free memory, it relaunches it for Botan (state restoration).
//   A user who swipes the app away in the app switcher stops all of this, as iOS wants.
//
// Safety:
//   * a press only counts with the token of the screen it was pressed on, and only for the request
//     still pending (BotanLinkScreen.decision); the Mac checks the fingerprint again before applying it;
//   * Botan allows or picks, never denies or types;
//   * Coucou links to one Botan: the first one it meets, remembered, and only that one afterwards
//     ("Forget this Botan" to change). A look-alike device nearby is never linked;
//   * off by default. A press on Botan does not ask for Face ID: that is the point of a button on the
//     back of the iPhone, and the switch says so.

@MainActor
@Observable
final class BotanBridge: NSObject {
    static let shared = BotanBridge()
    static let enabledKey = "botanEnabled"
    private static let knownKey = "botanPeripheral"
    private static let restoreID = "fr.louisraille.Coucou.botan"

    static let serviceUUID = CBUUID(string: "b07a0001-6d6f-6368-6900-626f74616e00")
    static let stateUUID = CBUUID(string: "b07a0002-6d6f-6368-6900-626f74616e00")
    static let eventUUID = CBUUID(string: "b07a0003-6d6f-6368-6900-626f74616e00")

    enum Status: Equatable {
        case off, bluetoothOff, unauthorized, searching, connecting, linked(String)
    }

    private(set) var status: Status = .off
    /// The Botan this iPhone links to, once met.
    private(set) var knownName: String?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var stateChar: CBCharacteristic?
    @ObservationIgnored private var shown: BotanScreen?
    @ObservationIgnored private var wanted: BotanScreen?
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var lastLook = Date.distantPast

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private static var knownID: UUID? {
        get { UserDefaults.standard.string(forKey: knownKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: knownKey) }
    }

    /// At launch, also when iOS relaunches the app in the background for Botan.
    func startIfEnabled() {
        knownName = UserDefaults.standard.string(forKey: Self.knownKey + "Name")
        if Self.isEnabled { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    /// Links the next Botan met instead of the remembered one.
    func forget() {
        Self.knownID = nil
        knownName = nil
        UserDefaults.standard.removeObject(forKey: Self.knownKey + "Name")
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        stateChar = nil
        shown = nil
        scan()
    }

    // MARK: Start and stop

    private func start() {
        guard central == nil else { return }
        // Main queue: every callback lands on the main actor. The restore identifier lets iOS
        // relaunch the app for Botan after ending it to free memory.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    private func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        central = nil
        peripheral = nil
        stateChar = nil
        shown = nil
        wanted = nil
        writing = false
        status = .off
    }

    private func scan() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        // The remembered Botan: a pending connection never times out on iOS, so it links again
        // by itself when Botan comes back in range or restarts, even with the iPhone locked.
        if let id = Self.knownID {
            if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
                connect(known)
                return
            }
        }
        status = .searching
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        status = .connecting
        central?.connect(p, options: nil)
    }

    // MARK: From iCloud to Botan

    /// PhoneLink calls this after each fetch (app open, push, or a tick).
    func sessionsChanged() {
        guard central != nil else { return }
        wanted = Self.screen(for: PhoneLink.shared.sessions)
        flush()
    }

    private func flush() {
        guard !writing, let p = peripheral, let ch = stateChar, let want = wanted, want != shown else { return }
        guard let data = want.line.data(using: .utf8), data.count <= p.maximumWriteValueLength(for: .withResponse) else { return }
        writing = true
        shown = want
        p.writeValue(data, for: ch, type: .withResponse)
    }

    /// The sessions as Botan's one screen: what waits on you first (the newest), then the rest.
    static func screen(for sessions: [SessionItem]) -> BotanScreen {
        let newest = sessions.sorted { $0.updatedAt > $1.updatedAt }
        let approval = newest.first { $0.needsApproval && !$0.approvalFingerprint.isEmpty }.map { s in
            BotanApprovalIn(requestId: s.approvalFingerprint, agent: s.pillName, project: s.cwd,
                            tool: s.approvalTool ?? "", command: s.approvalCommand)
        }
        let question = newest.first { $0.state == .question && $0.questionPayload != nil && !$0.questionFingerprint.isEmpty }
            .flatMap { s -> BotanQuestionIn? in
                guard let items = s.questionPayload?.items, let first = items.first else { return nil }
                return BotanQuestionIn(requestId: s.questionFingerprint, agent: s.pillName, project: s.cwd,
                                       question: first.question, options: first.options.map(\.label),
                                       multiSelect: first.multiSelect, count: items.count)
            }
        let shown = newest.map { s in
            BotanSessionIn(pillId: s.id, agent: s.pillName, state: s.state.rawValue,
                           statusText: s.currentStep ?? "", finalLine: s.finalLine, project: s.cwd)
        }
        return BotanLinkScreen.screen(sessions: shown, approval: approval, question: question)
    }

    // MARK: From Botan's button to the Mac

    private func handle(event: String) {
        if BotanLinkScreen.isTick(event) {
            // Wake-up call: look for news if the last look is a few seconds old.
            guard Date().timeIntervalSince(lastLook) > 8 else { return }
            lastLook = Date()
            runInBackground { _ = await PhoneLink.shared.handlePush() }
            return
        }
        switch BotanLinkScreen.decision(for: event, screen: shown) {
        case .allow(let fingerprint):
            guard let session = PhoneLink.shared.sessions.first(where: { $0.needsApproval && $0.approvalFingerprint == fingerprint })
            else { return }
            let summary = session.approvalCommand.isEmpty ? "Allowed from Botan" : String(session.approvalCommand.prefix(200))
            runInBackground {
                _ = await PhoneLink.shared.decide(.allow, fingerprint: fingerprint, pillId: session.id, summary: summary)
            }
        case .answer(let fingerprint, let label):
            guard let session = PhoneLink.shared.sessions.first(where: { $0.questionFingerprint == fingerprint }) else { return }
            runInBackground {
                _ = await PhoneLink.shared.answer(fingerprint: fingerprint, pillId: session.id, selections: [[label]])
            }
        case .ignore:
            break
        }
    }

    /// Work started from a Bluetooth wake-up: asks iOS for the few seconds it needs to reach iCloud.
    private func runInBackground(_ work: @escaping @MainActor @Sendable () async -> Void) {
        let task = BackgroundTime()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "Botan") { task.end() }
        Task { @MainActor in
            await work()
            task.end()
        }
    }
}

/// The background time asked for one piece of work, given back once (done or expired).
@MainActor
private final class BackgroundTime {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

// MARK: - Bluetooth callbacks (on the main queue)

// The central runs on the main queue, so every callback arrives on the main actor: the conformances
// say so (@preconcurrency checks it at run time instead of making each callback hop).
extension BotanBridge: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Relaunched by iOS for Botan: take back the link it kept.
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let p = peripheral {
                // Restored: carry on where it was.
                if p.state == .connected { p.discoverServices([Self.serviceUUID]) } else { central.connect(p, options: nil) }
            } else {
                scan()
            }
        case .unauthorized:
            status = .unauthorized
        default:
            stateChar = nil
            shown = nil
            writing = false
            status = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        // Only the remembered Botan, once there is one.
        if let id = Self.knownID, id != peripheral.identifier { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        relink(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        relink(peripheral)
    }

    /// Lost: wait for it to come back (a pending connection, kept by iOS even in the background).
    private func relink(_ p: CBPeripheral) {
        stateChar = nil
        shown = nil
        writing = false
        guard let central, central.state == .poweredOn else { return }
        if Self.knownID == p.identifier {
            status = .connecting
            central.connect(p, options: nil)
        } else {
            peripheral = nil
            scan()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.stateUUID, Self.eventUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == Self.stateUUID { stateChar = ch }
            if ch.uuid == Self.eventUUID { peripheral.setNotifyValue(true, for: ch) }
        }
        guard stateChar != nil else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        // The first Botan met is the one: remembered from now on.
        if Self.knownID == nil {
            Self.knownID = peripheral.identifier
            knownName = peripheral.name ?? "Botan"
            UserDefaults.standard.set(knownName, forKey: Self.knownKey + "Name")
        }
        status = .linked(peripheral.name ?? "Botan")
        shown = nil
        sessionsChanged()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if error != nil {
            shown = nil
            return
        }
        flush()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.eventUUID, let data = characteristic.value,
              let event = String(data: data, encoding: .utf8) else { return }
        handle(event: event)
    }
}
