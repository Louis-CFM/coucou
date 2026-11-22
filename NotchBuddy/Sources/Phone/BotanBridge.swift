import AccessorySetupKit
import CoreBluetooth
import Foundation
import Observation
import SwiftUI
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
//   * if iOS ends the app to free memory, it relaunches it for Botan (state restoration);
//   * Botan is set up with AccessorySetupKit (the system's "pair an accessory" sheet): since iOS 26,
//     that is what lets iOS relaunch the app for Botan even after the app was swiped away in the
//     app switcher (TN3115). Before iOS 26, a swipe stops the link until the app is opened again.
//
// Safety:
//   * a press only counts with the token of the screen it was pressed on, and only for the request
//     still pending (BotanLinkScreen.decision); the Mac checks the fingerprint again before applying it;
//   * Botan allows or picks, never denies or types;
//   * Coucou links to one Botan: the one picked in the system sheet, and only that one afterwards
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
        /// `setup`: no Botan picked yet (the system sheet, from "Find Botan").
        case off, setup, bluetoothOff, unauthorized, searching, connecting, pairing, linked(String)
    }

    private(set) var status: Status = .off
    /// The Botan this iPhone links to, once met.
    private(set) var knownName: String?
    /// What iOS answered when the system sheet could not open or the setup failed (shown in Settings).
    private(set) var problem: String?
    /// What Botan's screen shows now (the last line it took), for the card on the home screen.
    private(set) var showing: Showing?

    struct Showing: Equatable {
        var state: BotState
        var label: String
        var title: String
    }

    /// "[#token ]state|label|title|detail" as the card shows it.
    static func showing(from line: String) -> Showing? {
        var rest = Substring(line)
        if rest.hasPrefix("#"), let space = rest.firstIndex(of: " ") { rest = rest[rest.index(after: space)...] }
        let fields = rest.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3 else { return nil }
        return Showing(state: BotState(rawValue: fields[0]) ?? .idle, label: fields[1], title: fields[2])
    }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var accessories: ASAccessorySession?
    /// Show the system sheet as soon as the session is ready (the switch was just turned on).
    @ObservationIgnored private var pickWhenReady = false
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

    /// From the switch (the app is open): turning it on shows the system sheet when no Botan is set up.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            pickWhenReady = true
            start()
        } else {
            stop()
        }
    }

    /// The system sheet that finds Botan nearby ("Find Botan"). The app must be open.
    func findBotan() {
        guard let accessories else {
            // No session (ended, or the switch was just turned on): open one, the sheet follows.
            pickWhenReady = true
            activateAccessories()
            return
        }
        pickWhenReady = false
        // iOS opens its sheet only when the app holds no Bluetooth of its own (ASErrorDomain 550).
        closeCentral()
        let item = ASPickerDisplayItem(name: "Botan", productImage: Self.pickerImage(), descriptor: Self.descriptor())
        problem = nil
        accessories.showPicker(for: [item]) { error in
            // Dismissed or failed: the status stays "setup", "Find Botan" tries again.
            guard let error else { return }
            let text = Self.describe(error)
            print("Botan sheet: \(text)")
            Task { @MainActor in BotanBridge.shared.problem = text }
        }
    }

    /// Forgets this Botan (also on the iPhone's side), then waits for another to be picked.
    func forget() {
        if let session = accessories, let accessory = session.accessories.first(where: { $0.bluetoothIdentifier == Self.knownID }) {
            session.removeAccessory(accessory) { _ in }  // the removed event clears the rest
        }
        dropKnown()
    }

    private func dropKnown() {
        Self.knownID = nil
        knownName = nil
        UserDefaults.standard.removeObject(forKey: Self.knownKey + "Name")
        closeCentral()
        if accessories != nil { status = .setup }
    }

    /// Coucou's own Bluetooth, opened only for the Botan picked in the system sheet.
    private func openCentral() {
        guard central == nil else { return }
        // Main queue: every callback lands on the main actor. The restore identifier lets iOS
        // relaunch the app for Botan after ending it (and, on iOS 26, after a swipe).
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    private func closeCentral() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        central = nil
        peripheral = nil
        stateChar = nil
        shown = nil
        showing = nil
        writing = false
    }

    /// The Botan set up in the system sheet becomes the one Coucou links to.
    private func adopt(_ id: UUID, name: String) {
        guard Self.knownID != id || peripheral == nil else { return }
        if let p = peripheral, p.identifier != id { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        Self.knownID = id
        knownName = name
        UserDefaults.standard.set(name, forKey: Self.knownKey + "Name")
        status = .connecting
        if central == nil { openCentral() } else { scan() }  // a new central scans once powered on
    }

    nonisolated static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.localizedDescription) (\(e.domain) \(e.code))"
    }

    private func handle(accessoryEvent type: ASAccessoryEventType, id: UUID?, name: String?, error: String?) {
        if let error { problem = error }
        switch type {
        case .pickerDidPresent:
            problem = nil
        case .invalidated:
            accessories = nil
            if problem == nil { problem = "The accessory session ended." }
        case .activated:
            // The Botan set up before (or none: a link from before AccessorySetupKit is set up again).
            if let first = accessories?.accessories.first(where: { $0.bluetoothIdentifier != nil }),
               let id = first.bluetoothIdentifier {
                if Self.knownID != id || peripheral == nil { adopt(id, name: first.displayName) }
            } else {
                dropKnown()
                if pickWhenReady { findBotan() }
            }
        case .accessoryAdded, .accessoryChanged:
            if let id { adopt(id, name: name ?? "Botan") }
        case .accessoryRemoved:
            if id == nil || id == Self.knownID { dropKnown() }
        default:
            break
        }
    }

    static func descriptor() -> ASDiscoveryDescriptor {
        let d = ASDiscoveryDescriptor()
        d.bluetoothServiceUUID = serviceUUID
        return d
    }

    /// Mochi on Botan's black screen, for the system sheet.
    static func pickerImage() -> UIImage {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Color.black)
            MochiStill(showBadge: false).padding(34)
        }
        .frame(width: 200, height: 200)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }

    // MARK: Start and stop

    private func start() {
        guard accessories == nil else { return }
        // A Botan picked before: Bluetooth right away (iOS may be relaunching the app for it).
        if Self.knownID != nil {
            status = .connecting
            openCentral()
        }
        activateAccessories()
    }

    /// The system's accessory session: which Botan was picked, and the sheet to pick one.
    private func activateAccessories() {
        let session = ASAccessorySession()
        accessories = session
        session.activate(on: .main) { [weak self] event in
            let type = event.eventType
            let id = event.accessory?.bluetoothIdentifier
            let name = event.accessory?.displayName
            let error = event.error.map { Self.describe($0) }
            MainActor.assumeIsolated { self?.handle(accessoryEvent: type, id: id, name: name, error: error) }
        }
    }

    private func stop() {
        closeCentral()
        accessories?.invalidate()
        accessories = nil
        pickWhenReady = false
        wanted = nil
        status = .off
    }

    private func scan() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        // The remembered Botan: a pending connection never times out on iOS, so it links again
        // by itself when Botan comes back in range or restarts, even with the iPhone locked.
        // Only the Botan picked in the system sheet: no scanning around.
        guard let id = Self.knownID else {
            status = .setup
            return
        }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            // Not known to Bluetooth yet: look for it (only accessories set up in the sheet show up).
            status = .searching
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        }
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
        // Only the Botan picked in the system sheet.
        guard self.peripheral == nil, let id = Self.knownID, id == peripheral.identifier else { return }
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
        showing = nil
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
        // The first write needs the link encrypted: iOS asks for the code Botan shows the first time,
        // then remembers it. "Linked" once Botan took a line.
        status = .pairing
        shown = nil
        sessionsChanged()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if error != nil {
            // Not paired yet (the code is being typed), or a hiccup: try again in a moment.
            shown = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
            return
        }
        if case .linked = status {} else {
            // Botan took a line: paired and encrypted.
            status = .linked(knownName ?? peripheral.name ?? "Botan")
        }
        showing = shown.flatMap { Self.showing(from: $0.line) }
        flush()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // Listening to the button also needs the pairing: asked again until it is done.
        guard error != nil, characteristic.uuid == Self.eventUUID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.listenAgain() }
        }
    }

    /// Subscribes to the button again, on the Botan linked now (looked up, not carried along).
    private func listenAgain() {
        guard let p = peripheral, p.state == .connected,
              let ch = p.services?.first(where: { $0.uuid == Self.serviceUUID })?.characteristics?
                .first(where: { $0.uuid == Self.eventUUID }) else { return }
        p.setNotifyValue(true, for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.eventUUID, let data = characteristic.value,
              let event = String(data: data, encoding: .utf8) else { return }
        handle(event: event)
    }
}
