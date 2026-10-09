use std::io;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::CloseHandle;
use windows::Win32::System::Threading::{
    CreateProcessW, CREATE_NO_WINDOW, PROCESS_INFORMATION, STARTUPINFOW,
};

use super::files::LAUNCH_ARG;

pub fn spawn(exe: &Path) -> io::Result<u32> {
    let application: Vec<u16> = exe.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut command: Vec<u16> = "\""
        .encode_utf16()
        .chain(exe.as_os_str().encode_wide())
        .chain("\" ".encode_utf16())
        .chain(LAUNCH_ARG.encode_utf16())
        .chain(Some(0))
        .collect();
    let directory: Vec<u16> = exe
        .parent()
        .ok_or_else(|| io::Error::other("Coucou executable has no directory"))?
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let startup = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        ..Default::default()
    };
    let mut process = PROCESS_INFORMATION::default();
    // Command::spawn inherits every inheritable handle, including the hook's capture pipes.
    unsafe {
        CreateProcessW(
            PCWSTR(application.as_ptr()),
            Some(PWSTR(command.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_NO_WINDOW,
            None,
            PCWSTR(directory.as_ptr()),
            &startup,
            &mut process,
        )
        .map_err(io::Error::other)?;
        let _ = CloseHandle(process.hThread);
        let _ = CloseHandle(process.hProcess);
    }
    Ok(process.dwProcessId)
}
