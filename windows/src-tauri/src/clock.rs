// Local wall-clock time for the log and the settings.json backup names.
// No date crate for two timestamps: each platform already knows the local time.

/// Local time as (year, month, day, hour, minute, second).
#[cfg(windows)]
pub fn local_now() -> (u16, u16, u16, u16, u16, u16) {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    (t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond)
}

/// Local time as (year, month, day, hour, minute, second).
#[cfg(unix)]
pub fn local_now() -> (u16, u16, u16, u16, u16, u16) {
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&now, &mut tm).is_null() {
            return (1970, 1, 1, 0, 0, 0);
        }
        (
            (tm.tm_year + 1900) as u16,
            (tm.tm_mon + 1) as u16,
            tm.tm_mday as u16,
            tm.tm_hour as u16,
            tm.tm_min as u16,
            tm.tm_sec as u16,
        )
    }
}
