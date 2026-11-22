import Combine
import Foundation
#if !APPSTORE
// Only the GitHub build links Bluetooth (the App Store build has neither the entitlement nor the purpose string).
import CoreBluetooth
#endif

// MARK: - Botan link: the Bluetooth side (GitHub build)
//
// Botan advertises one service; Coucou connects to it, writes the line it should show on one
// characteristic and listens to its button on another (docs/BOTAN_LINK.md). Off by default and opt-in
// in Settings → Botan. While it is off, Bluetooth is not even opened. While it is on, the work is
// event driven: AppState changes (debounced) become one line, written only when it changes; the
// button's events are handled as they arrive. No polling.
//
// The island keeps owning the sessions and the pending request. A press is checked by
// `BotanLinkScreen.decision` (the token of the screen it was pressed on must be the request still
// pending), then checked again here on the main actor, and answered through
// `HookServer.sendApprovalDecision` / `sendQuestionAnswers`: the very path a click on the Mac's own
// card takes, so the card keeps working all along. A press on Botan is the explicit click.
//
// Compiled out of the App Store build for now (it would need the sandbox's Bluetooth entitlement).

#if !APPSTORE

@MainActor
final class BotanLinkService: NSObject, ObservableObject {
    static let shared = BotanLinkService()
    static let enabledKey = "botanLinkEnabled"
    /// The Botan this Mac links to: the first one met, and only that one afterwards.
    static let knownKey = "botanLinkPeripheral"

    static let serviceUUID = CBUUID(string: "b07a0001-6d6f-6368-6900-626f74616e00")
    static let stateUUID = CBUUID(string: "b07a0002-6d6f-6368-6900-626f74616e00")   // write: the line
    static let eventUUID = CBUUID(string: "b07a0003-6d6f-6368-6900-626f74616e00")   // notify: the button

    enum Status: Equatable {
        case off, bluetoothOff, unauthorized, searching, connecting, linked(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var hasKnown = UserDefaults.standard.string(forKey: BotanLinkService.knownKey) != nil

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var stateChar: CBCharacteristic?
    private var cancellable: AnyCancellable?
    /// What Botan shows now (nil until written), and what it should show.
    private var shown: BotanScreen?
    private var wanted: BotanScreen?
    private var writing = false

    nonisolated static func log(_ message: String) {
        appendAppLog("BotanLink.log", message)
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    private static var knownID: UUID? {
        get { UserDefaults.standard.string(forKey: knownKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: knownKey) }
    }

    /// Links the next Botan met instead of the remembered one.
    func forget() {
        Self.knownID = nil
        hasKnown = false
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        lost()
        Self.log("forgot the remembered Botan")
    }

    // MARK: Start and stop

    private func start() {
        guard central == nil else { return }
        // The queue is the main one: every callback lands on the main actor.
        central = CBCentralManager(delegate: self, queue: .main)
        observe()
        Self.log("starting")
    }

    private func stop() {
        cancellable = nil
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        central = nil
        peripheral = nil
        stateChar = nil
        shown = nil
        wanted = nil
        writing = false
        status = .off
        Self.log("stopped")
    }

    private func scan() {
        guard let central, central.state == .poweredOn else { return }
        // The remembered Botan: a pending connection, made again by the system when it comes back.
        if let id = Self.knownID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
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

    private func lost() {
        peripheral = nil
        stateChar = nil
        shown = nil
        writing = false
        if central != nil { scan() }
    }

    // MARK: From the island to Botan

    private func observe() {
        let s = AppState.shared
        let sources: [AnyPublisher<Void, Never>] = [
            s.$tasks.map { _ in () }.eraseToAnyPublisher(),
            s.$pendingApproval.map { _ in () }.eraseToAnyPublisher(),
            s.$waitingQuestions.map { _ in () }.eraseToAnyPublisher(),
            DemoEngine.shared.$isActive.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published sends before the property changes: the debounce lets the value settle, and it is read back.
        cancellable = Publishers.MergeMany(sources)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.publish() }
            }
    }

    private func publish() {
        wanted = Self.currentScreen()
        flush()
    }

    /// Writes the wanted line if Botan does not show it yet; one write at a time.
    private func flush() {
        guard !writing, let p = peripheral, let ch = stateChar, let want = wanted, want != shown else { return }
        guard let data = want.line.data(using: .utf8), data.count <= p.maximumWriteValueLength(for: .withResponse) else {
            Self.log("line too long for this connection, not sent")
            return
        }
        writing = true
        shown = want
        p.writeValue(data, for: ch, type: .withResponse)
    }

    /// The island's picture, as Botan's one screen. The demo is not real: Botan is told nothing runs.
    static func currentScreen() -> BotanScreen {
        let state = AppState.shared
        if DemoEngine.shared.isActive {
            return BotanLinkScreen.screen(sessions: [], approval: nil, question: nil)
        }
        let approval = state.pendingApproval.flatMap { info -> BotanApprovalIn? in
            guard info.sessionId != "demo_session" else { return nil }
            return BotanApprovalIn(requestId: info.id.uuidString, agent: agentName(for: info.pillId, tasks: state.tasks),
                                   project: info.projectName, tool: info.tool, command: info.command)
        }
        let question = state.waitingQuestions.first.map { entry in
            BotanQuestionIn(requestId: entry.id.uuidString, agent: agentName(for: entry.pillId, tasks: state.tasks),
                            project: entry.projectName,
                            question: entry.question.questions.first?.question ?? "",
                            options: entry.question.questions.first?.options.map(\.label) ?? [],
                            multiSelect: entry.question.questions.first?.multiSelect ?? false,
                            count: entry.question.questions.count)
        }
        return BotanLinkScreen.screen(sessions: sessions(from: state.tasks), approval: approval, question: question)
    }

    /// Agent sessions and n8n workflows; services (Stripe, GitHub…) and chat providers are not shown.
    static func sessions(from tasks: [AgentTask]) -> [BotanSessionIn] {
        tasks.compactMap { task in
            let current = task.steps.indices.contains(task.stepIndex) ? task.steps[task.stepIndex] : (task.steps.last ?? "")
            if task.source == .n8n {
                return BotanSessionIn(pillId: task.id, agent: "n8n", state: task.state.rawValue, statusText: current,
                                      finalLine: task.finalLine, project: task.name, isWorkflow: true)
            }
            guard PillCatalog.isSession(task.id) else { return nil }
            return BotanSessionIn(pillId: task.id, agent: task.name, state: task.state.rawValue, statusText: current,
                                  finalLine: task.finalLine, project: task.sessionCwd)
        }
    }

    private static func agentName(for pillId: String, tasks: [AgentTask]) -> String {
        tasks.first { $0.pill == PillCatalog.basePillId(pillId) }?.name
            ?? PillCatalog.definition(for: PillCatalog.basePillId(pillId))?.name
            ?? "Claude Code"
    }

    // MARK: From Botan's button to the island

    private func handle(event: String) {
        if BotanLinkScreen.isTick(event) { return }  // the Mac is awake anyway
        switch BotanLinkScreen.decision(for: event, screen: shown) {
        case .allow(let requestId):
            // Checked again right before answering the hook: the request must still be the one on the card.
            guard let pending = AppState.shared.pendingApproval, pending.id.uuidString == requestId else {
                Self.log("approval pressed after the request was resolved, ignored")
                return
            }
            Self.log("allowed from Botan: \(pending.tool)")
            HookServer.shared.sendApprovalDecision("allow", for: pending.id)
        case .answer(let requestId, let label):
            guard let entry = AppState.shared.waitingQuestions.first(where: { $0.id.uuidString == requestId }) else {
                Self.log("answer for a question no longer waiting, ignored")
                return
            }
            // Never what was picked.
            Self.log("answered a question from Botan")
            HookServer.shared.sendQuestionAnswers(
                AskQuestion.buildAnswers(questions: entry.question.questions, selections: [[label]]), for: entry.id)
        case .ignore(let why):
            Self.log("button: \(why)")
        }
    }
}

// MARK: - Bluetooth callbacks (on the main queue)

// The central runs on the main queue, so every callback arrives on the main actor: the conformances
// say so (@preconcurrency checks it at run time instead of making each callback hop).
extension BotanLinkService: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scan()
        case .unauthorized: status = .unauthorized
        default:
            peripheral = nil
            stateChar = nil
            shown = nil
            writing = false
            status = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        // Only the remembered Botan, once there is one: a look-alike nearby is never linked.
        if let id = Self.knownID, id != peripheral.identifier { return }
        Self.log("found \(peripheral.name ?? "Botan")")
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Self.log("could not connect: \(error?.localizedDescription ?? "unknown")")
        lost()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Self.log("disconnected")
        lost()
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
        if Self.knownID == nil {
            Self.knownID = peripheral.identifier
            hasKnown = true
        }
        status = .linked(peripheral.name ?? "Botan")
        Self.log("linked")
        shown = nil
        publish()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if let error {
            Self.log("write failed: \(error.localizedDescription)")
            shown = nil  // written again with the next change
            return
        }
        flush()  // something changed while this line was on its way
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.eventUUID, let data = characteristic.value,
              let event = String(data: data, encoding: .utf8) else { return }
        handle(event: event)
    }
}

#endif
