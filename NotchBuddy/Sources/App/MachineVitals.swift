import AppKit
import Combine
import Darwin
import IOKit.ps

/// How the Mac is doing, as Mochi shows it: a busy processor makes him sweat, a warm Mac
/// flushes him, short memory puffs him up, a low battery makes him tired, then asleep.
///
/// It only reads while Mochi is on screen (the island showing, or Mochi on the desktop), every
/// few seconds: a hidden island costs nothing. Everything stays on the Mac.
@MainActor
final class MachineVitals: ObservableObject {
    static let shared = MachineVitals()

    static let enabledKey = "mochiFeelsTheMac"

    /// What Mochi shows, read by his canvases every frame.
    @Published private(set) var mood = MochiMood.calm
    /// The line shown under the island while the pointer is on Mochi ("CPU 94 % · node, Chrome").
    @Published private(set) var summary: String? = nil
    /// The pointer is on Mochi (set by the island's poll).
    @Published var hovered = false

    /// Off in Settings → General: Mochi no longer reacts to the Mac.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            refreshRunning()
        }
    }

    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var memoryLevel: CGFloat = 0
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var cpu: Double = 0
    private var busySamples = 0
    private var lastProcessTimes: [pid_t: UInt64] = [:]
    private var topProcesses: [String] = []
    private var battery: (percent: Int, onPower: Bool)? = nil

    private init() {}

    /// Starts following whether Mochi is on screen. Called once at launch.
    func start() {
        let state = AppState.shared
        // Everything is received on the main thread: macOS posts some of these (the thermal
        // state) from a background queue, and Mochi's code only runs on the main one.
        state.$mode.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }.store(in: &subscriptions)
        state.$mochiOnDesktop.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.sample() } }
            .store(in: &subscriptions)
        refreshRunning()
    }

    private var onScreen: Bool {
        AppState.shared.mode != .hidden || AppState.shared.mochiOnDesktop
    }

    private func refreshRunning() {
        let run = enabled && onScreen
        if run, timer == nil {
            lastTicks = nil
            lastProcessTimes = [:]
            watchMemory()
            sample()
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sample() }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run, timer != nil {
            timer?.invalidate()
            timer = nil
            memoryPressure?.cancel()
            memoryPressure = nil
            if !enabled { mood = .calm; summary = nil }
        }
    }

    // MARK: - Reading the Mac

    private func sample() {
        guard enabled else { return }
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
            }
            lastTicks = ticks
        }
        // Two readings in a row above 80 %: a short spike does not make him sweat.
        busySamples = cpu >= 0.8 ? busySamples + 1 : 0
        let wasLow = (battery?.onPower == false) && (battery?.percent ?? 100) < 20
        battery = Self.readBattery()
        let isLow = (battery?.onPower == false) && (battery?.percent ?? 100) < 20
        if wasLow && !isLow && battery?.onPower == true {
            // Plugged in while tired: he wakes up.
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            SoundEngine.shared.play("pop")
        }
        if busySamples >= 2 { topProcesses = topProcessNames() } else { lastProcessTimes = [:]; topProcesses = [] }

        var next = MochiMood()
        next.busy = busySamples >= 2 ? CGFloat(min(1, (cpu - 0.6) / 0.3)) : 0
        switch ProcessInfo.processInfo.thermalState {
        case .fair:     next.hot = 0.4
        case .serious:  next.hot = 0.8
        case .critical: next.hot = 1
        default:        next.hot = 0
        }
        next.full = memoryLevel
        if let b = battery, !b.onPower {
            next.tired = b.percent < 20 ? 1 : 0
            next.asleep = b.percent < 10
        }
        if next != mood { mood = next }
        let line = Self.describe(next, cpu: cpu, battery: battery, top: topProcesses)
        if line != summary { summary = line }
    }

    private func watchMemory() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressure?.data else { return }
                self.memoryLevel = event.contains(.critical) ? 1 : (event.contains(.warning) ? 0.6 : 0)
                self.sample()
            }
        }
        source.resume()
        memoryPressure = source
    }

    /// The words under the island, the most telling first.
    static func describe(_ mood: MochiMood, cpu: Double, battery: (percent: Int, onPower: Bool)?, top: [String]) -> String? {
        var parts: [String] = []
        if mood.busy > 0 {
            let pct = Int((cpu * 100).rounded())
            parts.append(top.isEmpty ? "CPU \(pct) %" : "CPU \(pct) % · \(top.prefix(2).joined(separator: ", "))")
        }
        if mood.hot >= 0.8 { parts.append(String(localized: "vitals.hot")) }
        else if mood.hot > 0 { parts.append(String(localized: "vitals.warm")) }
        if mood.full >= 1 { parts.append(String(localized: "vitals.memory-full")) }
        else if mood.full > 0 { parts.append(String(localized: "vitals.memory-short")) }
        if let b = battery, mood.tired > 0 || mood.asleep {
            parts.append(String(format: String(localized: "vitals.battery %lld"), b.percent))
        }
        return parts.isEmpty ? nil : parts.prefix(2).joined(separator: " · ")
    }

    /// All the processor time since boot: (busy, total) ticks over every core.
    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// The internal battery: its charge and whether the Mac is plugged in. Nil on a desktop Mac.
    private static func readBattery() -> (percent: Int, onPower: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        for source in list as Array {
            guard let desc = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onPower = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (Int((Double(current) / Double(max) * 100).rounded()), onPower)
        }
        return nil
    }

    /// The apps using the processor the most since the last reading ("node", "Google Chrome").
    private func topProcessNames() -> [String] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [] }
        var times: [pid_t: UInt64] = [:]
        var deltas: [(pid: pid_t, delta: UInt64)] = []
        let own = getpid()
        for pid in pids.prefix(Int(found)) where pid > 0 && pid != own {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0 else { continue }
            let total = usage.ri_user_time + usage.ri_system_time
            times[pid] = total
            if let before = lastProcessTimes[pid], total > before { deltas.append((pid, total - before)) }
        }
        lastProcessTimes = times
        var names: [String] = []
        for entry in deltas.sorted(by: { $0.delta > $1.delta }) {
            let name = Self.displayName(pid: entry.pid)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
            if names.count == 2 { break }
        }
        return names
    }

    /// "Google Chrome" for its helpers, the app's name when it has one, else the process name.
    private static func displayName(pid: pid_t) -> String {
        var name: String
        if let app = NSRunningApplication(processIdentifier: pid), let local = app.localizedName {
            name = local
        } else {
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, 256)
            name = String(cString: buffer)
        }
        if let range = name.range(of: " Helper") { name = String(name[..<range.lowerBound]) }
        return name
    }
}
