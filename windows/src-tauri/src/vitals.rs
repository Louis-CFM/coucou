// Mochi feels the computer — port of NotchBuddy/Sources/App/MachineVitals.swift.
//
// A busy processor makes him sweat, a warm machine flushes him, short memory
// puffs him up, a low battery makes him tired, then asleep. Read every three
// seconds, and only while Mochi is on screen (the page turns the reader on and
// off with `vitals_set_active`): a hidden island costs nothing. Everything
// stays on the computer.
//
// The reading is Windows' (GetSystemTimes, GlobalMemoryStatusEx,
// GetSystemPowerStatus, the thermal zones' performance counter); turning it
// into a mood is plain Rust, shared and tested.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

/// Seconds between two readings, as on the Mac.
const PERIOD: Duration = Duration::from_secs(3);

/// The battery as Mochi sees it.
#[derive(Serialize, Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Battery {
    pub percent: u8,
    pub on_power: bool,
}

/// One reading of the computer.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Sample {
    /// Share of all processor time spent busy since the last reading, 0…1.
    pub cpu: f64,
    /// Share of physical memory in use, 0…100.
    pub memory_load: u32,
    /// Physical memory in use and in all, bytes (0 when unknown).
    pub memory_used: u64,
    pub memory_total: u64,
    /// The warmest thermal zone, °C, when Windows reports one.
    pub temperature: Option<f64>,
    pub battery: Option<Battery>,
}

/// What the page is told: the mood's levels, and what explains them.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Mood {
    pub busy: f64,
    pub hot: f64,
    pub full: f64,
    pub tired: f64,
    pub asleep: bool,
    /// 0…1, for "CPU 94 %".
    pub cpu: f64,
    /// The programs using the processor the most, while it is busy.
    pub top: Vec<String>,
    pub battery: Option<Battery>,
    /// Plugged in while he was tired: he wakes up (a happy hop and a pop).
    pub woke: bool,
    /// What the hover line shows as numbers.
    pub memory: Option<Memory>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Memory {
    pub percent: u32,
    pub used_gb: f64,
    pub total_gb: f64,
}

impl Mood {
    /// Nothing to show: the reader is off.
    pub fn calm() -> Self {
        Mood { busy: 0.0, hot: 0.0, full: 0.0, tired: 0.0, asleep: false, cpu: 0.0, top: Vec::new(), battery: None, woke: false, memory: None }
    }
}

/// Turns readings into a mood, remembering what the Mac's MachineVitals does
/// between them: a short spike does not make him sweat.
#[derive(Default)]
pub struct Moodmaker {
    busy_samples: u32,
    was_low: bool,
}

impl Moodmaker {
    pub fn next(&mut self, s: &Sample, top: Vec<String>) -> Mood {
        // Two readings in a row above 80 %.
        self.busy_samples = if s.cpu >= 0.8 { self.busy_samples + 1 } else { 0 };
        let busy = if self.busy_samples >= 2 { ((s.cpu - 0.6) / 0.3).clamp(0.0, 1.0) } else { 0.0 };

        let low = |b: Option<Battery>| b.is_some_and(|b| !b.on_power && b.percent < 20);
        let is_low = low(s.battery);
        let woke = self.was_low && !is_low && s.battery.is_some_and(|b| b.on_power);
        self.was_low = is_low;

        let (tired, asleep) = match s.battery {
            Some(b) if !b.on_power => (if b.percent < 20 { 1.0 } else { 0.0 }, b.percent < 10),
            _ => (0.0, false),
        };
        Mood {
            busy,
            hot: heat_level(s.temperature),
            full: memory_level(s.memory_load),
            tired,
            asleep,
            cpu: s.cpu,
            top: if busy > 0.0 { top } else { Vec::new() },
            battery: s.battery,
            woke,
            memory: (s.memory_total > 0).then(|| Memory {
                percent: s.memory_load,
                used_gb: s.memory_used as f64 / GB,
                total_gb: s.memory_total as f64 / GB,
            }),
        }
    }

    /// Whether the busiest programs are worth looking up on this reading.
    pub fn wants_top(&self, cpu: f64) -> bool {
        cpu >= 0.8 && self.busy_samples >= 1
    }
}

/// The warmest zone in °C → the Mac's thermal states: fair 0.4, serious 0.8,
/// critical 1. Thermal zones read a little below the processor itself.
pub fn heat_level(celsius: Option<f64>) -> f64 {
    match celsius {
        Some(c) if c >= 95.0 => 1.0,
        Some(c) if c >= 88.0 => 0.8,
        Some(c) if c >= 80.0 => 0.4,
        _ => 0.0,
    }
}

const GB: f64 = 1024.0 * 1024.0 * 1024.0;

/// Physical memory in use → the Mac's memory pressure: warning 0.6, critical 1.
pub fn memory_level(load: u32) -> f64 {
    if load >= 95 {
        1.0
    } else if load >= 88 {
        0.6
    } else {
        0.0
    }
}

/// "chrome.exe" → "Google Chrome": the names people know, else the program's.
pub fn display_name(exe: &str) -> String {
    let stem = exe.strip_suffix(".exe").or_else(|| exe.strip_suffix(".EXE")).unwrap_or(exe);
    let known = match stem.to_lowercase().as_str() {
        "chrome" => "Google Chrome",
        "msedge" | "msedgewebview2" => "Microsoft Edge",
        "firefox" => "Firefox",
        "brave" => "Brave",
        "opera" => "Opera",
        "code" => "VS Code",
        "cursor" => "Cursor",
        "claude" => "Claude",
        "explorer" => "Explorer",
        "msmpeng" => "Microsoft Defender",
        "searchindexer" | "searchprotocolhost" => "Windows Search",
        "teams" | "ms-teams" => "Teams",
        "discord" => "Discord",
        "spotify" => "Spotify",
        "obs64" => "OBS",
        "dwm" => "Desktop Window Manager",
        "rustc" | "cargo" => "Rust",
        "node" => "node",
        "python" | "pythonw" => "Python",
        _ => "",
    };
    if known.is_empty() { stem.to_string() } else { known.to_string() }
}

/// The two names that used the most processor time since the last reading,
/// adding up every process of one program (Chrome has dozens).
pub fn top_names(before: &HashMap<u32, u64>, now: &HashMap<u32, (String, u64)>) -> Vec<String> {
    let mut by_name: HashMap<String, u64> = HashMap::new();
    for (pid, (name, total)) in now {
        if let Some(prev) = before.get(pid) {
            if total > prev {
                *by_name.entry(display_name(name)).or_default() += total - prev;
            }
        }
    }
    let mut ranked: Vec<(String, u64)> = by_name.into_iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    ranked.into_iter().take(2).map(|(n, _)| n).collect()
}

// ── The reader ────────────────────────────────────────────────────────────────

/// Bumped on every on/off, so a reader left over from before stops.
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// Turns the reader on while Mochi is on screen (and the setting is on), off otherwise.
#[tauri::command]
pub fn vitals_set_active(app: AppHandle, on: bool) {
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    if !on || !cfg!(windows) {
        // Off: both Mochis go back to calm rather than keep the last mood.
        let _ = app.emit("vitals", Mood::calm());
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("coucou-vitals".into())
        .spawn(move || read_while(app, generation));
    if let Err(err) = spawned {
        crate::log::line(format!("vitals: no reader thread: {err}"));
    }
}

fn read_while(app: AppHandle, generation: u64) {
    let current = || GENERATION.load(Ordering::SeqCst) == generation;
    let mut reader = os::Reader::new();
    let mut maker = Moodmaker::default();
    let mut last: Option<Mood> = None;
    while current() {
        let sample = reader.sample();
        let top = if maker.wants_top(sample.cpu) { reader.top_programs() } else { reader.forget_programs(); Vec::new() };
        let mood = maker.next(&sample, top);
        if last.as_ref() != Some(&mood) {
            let _ = app.emit("vitals", &mood);
            last = Some(mood);
        }
        // Slept in short steps, so turning it off is felt at once.
        for _ in 0..30 {
            if !current() {
                return;
            }
            std::thread::sleep(PERIOD / 30);
        }
    }
}

#[cfg(windows)]
mod os {
    use super::{Battery, Sample};
    use std::collections::HashMap;
    use windows::core::w;
    use windows::Win32::Foundation::{CloseHandle, FILETIME};
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
    };
    use windows::Win32::System::Performance::{
        PdhAddEnglishCounterW, PdhCloseQuery, PdhCollectQueryData, PdhGetFormattedCounterArrayW, PdhOpenQueryW,
        PDH_FMT_COUNTERVALUE_ITEM_W, PDH_FMT_DOUBLE, PDH_HCOUNTER, PDH_HQUERY,
    };
    use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    use windows::Win32::System::Threading::{
        GetCurrentProcessId, GetProcessTimes, GetSystemTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    fn ticks(t: FILETIME) -> u64 {
        ((t.dwHighDateTime as u64) << 32) | t.dwLowDateTime as u64
    }

    pub struct Reader {
        last_cpu: Option<(u64, u64)>,
        cpu: f64,
        programs: HashMap<u32, u64>,
        thermal: Option<(PDH_HQUERY, PDH_HCOUNTER)>,
    }

    impl Reader {
        pub fn new() -> Self {
            Self { last_cpu: None, cpu: 0.0, programs: HashMap::new(), thermal: open_thermal() }
        }

        pub fn sample(&mut self) -> Sample {
            if let Some((busy, total)) = cpu_ticks() {
                if let Some((b0, t0)) = self.last_cpu {
                    if total > t0 {
                        self.cpu = (busy.saturating_sub(b0)) as f64 / (total - t0) as f64;
                    }
                }
                self.last_cpu = Some((busy, total));
            }
            let (memory_load, memory_used, memory_total) = memory();
            Sample {
                cpu: self.cpu.clamp(0.0, 1.0),
                memory_load,
                memory_used,
                memory_total,
                temperature: self.thermal.and_then(|(q, c)| temperature(q, c)),
                battery: battery(),
            }
        }

        pub fn top_programs(&mut self) -> Vec<String> {
            let now = process_times();
            let names = super::top_names(&self.programs, &now);
            self.programs = now.into_iter().map(|(pid, (_, t))| (pid, t)).collect();
            names
        }

        pub fn forget_programs(&mut self) {
            self.programs.clear();
        }
    }

    impl Drop for Reader {
        fn drop(&mut self) {
            if let Some((q, _)) = self.thermal.take() {
                unsafe {
                    let _ = PdhCloseQuery(q);
                }
            }
        }
    }

    /// (busy, total) processor time since boot over every core.
    fn cpu_ticks() -> Option<(u64, u64)> {
        let (mut idle, mut kernel, mut user) = (FILETIME::default(), FILETIME::default(), FILETIME::default());
        unsafe { GetSystemTimes(Some(&mut idle), Some(&mut kernel), Some(&mut user)).ok()? };
        // Kernel time includes the idle time.
        let total = ticks(kernel) + ticks(user);
        Some((total.saturating_sub(ticks(idle)), total))
    }

    /// (load %, used bytes, total bytes), as Task Manager counts them.
    fn memory() -> (u32, u64, u64) {
        let mut status = MEMORYSTATUSEX { dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32, ..Default::default() };
        if unsafe { GlobalMemoryStatusEx(&mut status) }.is_ok() {
            (status.dwMemoryLoad, status.ullTotalPhys.saturating_sub(status.ullAvailPhys), status.ullTotalPhys)
        } else {
            (0, 0, 0)
        }
    }

    /// The internal battery, or None on a desktop computer.
    fn battery() -> Option<Battery> {
        let mut s = SYSTEM_POWER_STATUS::default();
        unsafe { GetSystemPowerStatus(&mut s).ok()? };
        // 128: no system battery; 255: unknown.
        if s.BatteryFlag == 128 || s.BatteryFlag == 255 || s.BatteryLifePercent > 100 {
            return None;
        }
        Some(Battery { percent: s.BatteryLifePercent, on_power: s.ACLineStatus == 1 })
    }

    /// The thermal zones' counter, which any user may read (no admin rights).
    fn open_thermal() -> Option<(PDH_HQUERY, PDH_HCOUNTER)> {
        unsafe {
            let mut query = PDH_HQUERY::default();
            if PdhOpenQueryW(None, 0, &mut query) != 0 {
                return None;
            }
            let mut counter = PDH_HCOUNTER::default();
            let path = w!("\\Thermal Zone Information(*)\\High Precision Temperature");
            if PdhAddEnglishCounterW(query, path, 0, &mut counter) != 0 {
                let _ = PdhCloseQuery(query);
                return None;
            }
            Some((query, counter))
        }
    }

    /// The warmest zone, °C. The counter is in tenths of a kelvin.
    fn temperature(query: PDH_HQUERY, counter: PDH_HCOUNTER) -> Option<f64> {
        unsafe {
            if PdhCollectQueryData(query) != 0 {
                return None;
            }
            let (mut size, mut count) = (0u32, 0u32);
            let _ = PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE, &mut size, &mut count, None);
            if size == 0 {
                return None;
            }
            let n = (size as usize).div_ceil(std::mem::size_of::<PDH_FMT_COUNTERVALUE_ITEM_W>()) + 1;
            let mut items = vec![PDH_FMT_COUNTERVALUE_ITEM_W::default(); n];
            if PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE, &mut size, &mut count, Some(items.as_mut_ptr())) != 0 {
                return None;
            }
            items
                .iter()
                .take(count as usize)
                .map(|i| i.FmtValue.Anonymous.doubleValue / 10.0 - 273.15)
                .filter(|c| (1.0..150.0).contains(c))
                .reduce(f64::max)
        }
    }

    /// Every process's file name and its processor time so far.
    fn process_times() -> HashMap<u32, (String, u64)> {
        let mut out = HashMap::new();
        let own = unsafe { GetCurrentProcessId() };
        unsafe {
            let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return out };
            let mut entry = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
            let mut ok = Process32FirstW(snap, &mut entry).is_ok();
            while ok {
                let pid = entry.th32ProcessID;
                if pid > 4 && pid != own {
                    if let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
                        let (mut c, mut e, mut k, mut u) =
                            (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
                        if GetProcessTimes(h, &mut c, &mut e, &mut k, &mut u).is_ok() {
                            let len = entry.szExeFile.iter().position(|&ch| ch == 0).unwrap_or(entry.szExeFile.len());
                            let name = String::from_utf16_lossy(&entry.szExeFile[..len]);
                            out.insert(pid, (name, ticks(k) + ticks(u)));
                        }
                        let _ = CloseHandle(h);
                    }
                }
                ok = Process32NextW(snap, &mut entry).is_ok();
            }
            let _ = CloseHandle(snap);
        }
        out
    }
}

#[cfg(not(windows))]
mod os {
    use super::Sample;

    /// Linux and others: not read yet, so Mochi stays calm.
    pub struct Reader;

    impl Reader {
        pub fn new() -> Self {
            Reader
        }
        pub fn sample(&mut self) -> Sample {
            Sample::default()
        }
        pub fn top_programs(&mut self) -> Vec<String> {
            Vec::new()
        }
        pub fn forget_programs(&mut self) {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(cpu: f64) -> Sample {
        Sample { cpu, ..Sample::default() }
    }

    /// Reads this very computer: `cargo test vitals -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn reads_this_computer() {
        let mut r = os::Reader::new();
        let _ = r.sample();
        let _ = r.top_programs();
        std::thread::sleep(Duration::from_millis(1500));
        let s = r.sample();
        println!("LIVE cpu={:.1}% memory={}% temperature={:?} battery={:?} top={:?}",
            s.cpu * 100.0, s.memory_load, s.temperature, s.battery, r.top_programs());
        assert!((0.0..=1.0).contains(&s.cpu));
        assert!(s.memory_load > 0 && s.memory_load <= 100);
    }

    #[test]
    fn a_short_spike_does_not_make_him_sweat() {
        let mut m = Moodmaker::default();
        assert_eq!(m.next(&sample(0.95), vec!["node".into()]).busy, 0.0);
        let mood = m.next(&sample(0.95), vec!["node".into()]);
        assert!(mood.busy > 0.9, "{mood:?}");
        assert_eq!(mood.top, vec!["node".to_string()]);
        // Back to calm: the names go with it.
        let calm = m.next(&sample(0.2), vec!["node".into()]);
        assert_eq!((calm.busy, calm.top.len()), (0.0, 0));
    }

    #[test]
    fn the_battery_makes_him_tired_then_asleep_and_power_wakes_him() {
        let mut m = Moodmaker::default();
        let on_battery = |percent| Sample { battery: Some(Battery { percent, on_power: false }), ..Sample::default() };
        let tired = m.next(&on_battery(15), Vec::new());
        assert_eq!((tired.tired, tired.asleep, tired.woke), (1.0, false, false));
        let asleep = m.next(&on_battery(8), Vec::new());
        assert!(asleep.asleep);
        let plugged = m.next(&Sample { battery: Some(Battery { percent: 8, on_power: true }), ..Sample::default() }, Vec::new());
        assert_eq!((plugged.tired, plugged.asleep, plugged.woke), (0.0, false, true));
        // A desktop computer has no battery: never tired.
        assert_eq!(m.next(&Sample::default(), Vec::new()).tired, 0.0);
    }

    #[test]
    fn heat_and_memory_follow_the_macs_levels() {
        assert_eq!(heat_level(None), 0.0);
        assert_eq!(heat_level(Some(60.0)), 0.0);
        assert_eq!(heat_level(Some(82.0)), 0.4);
        assert_eq!(heat_level(Some(90.0)), 0.8);
        assert_eq!(heat_level(Some(97.0)), 1.0);
        assert_eq!(memory_level(70), 0.0);
        assert_eq!(memory_level(90), 0.6);
        assert_eq!(memory_level(97), 1.0);
    }

    #[test]
    fn the_busiest_programs_add_up_all_their_processes() {
        let before: HashMap<u32, u64> = [(1, 100), (2, 100), (3, 100), (4, 100)].into();
        let now: HashMap<u32, (String, u64)> = [
            (1, ("chrome.exe".to_string(), 400)),
            (2, ("chrome.exe".to_string(), 400)),
            (3, ("node.exe".to_string(), 450)),
            (4, ("code.exe".to_string(), 150)),
            (5, ("new.exe".to_string(), 9999)),
        ]
        .into();
        assert_eq!(top_names(&before, &now), vec!["Google Chrome".to_string(), "node".to_string()]);
        assert_eq!(display_name("SomeTool.exe"), "SomeTool");
    }
}
