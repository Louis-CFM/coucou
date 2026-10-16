//! Links the Visual C++ runtime statically into coucou-hook.exe.
//!
//! Without this the relay imports VCRUNTIME140.dll, and on a PC without the
//! Visual C++ Redistributable it dies before its own code runs (0xC0000135,
//! STATUS_DLL_NOT_FOUND): Claude Code only sees a failed hook, with no stderr.
//! The app does not have the problem because tauri-build does exactly this for
//! it; this is the same technique (from github.com/ChrisDenton/static_vcruntime,
//! as vendored by tauri-build): vcruntime static, the Universal CRT dynamic —
//! the UCRT ships with Windows 10 and later.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let windows_msvc = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc");
    if !windows_msvc {
        return;
    }
    override_msvcrt_lib();
    // Libraries that would pull in the DLL runtime.
    for lib in [
        "libvcruntimed.lib", "vcruntime.lib", "vcruntimed.lib", "libcmtd.lib",
        "msvcrt.lib", "msvcrtd.lib", "libucrt.lib", "libucrtd.lib",
    ] {
        println!("cargo:rustc-link-arg=/NODEFAULTLIB:{lib}");
    }
    // The ones we want instead.
    for lib in ["libcmt.lib", "libvcruntime.lib", "ucrt.lib"] {
        println!("cargo:rustc-link-arg=/DEFAULTLIB:{lib}");
    }
}

/// rustc hard-codes msvcrt.lib; replace it with an (almost) empty object file.
fn override_msvcrt_lib() {
    let machine: &[u8] = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("x86_64") => &[0x64, 0x86],
        Ok("x86") => &[0x4C, 0x01],
        _ => return,
    };
    let bytes: &[u8] = &[
        1, 0, 94, 3, 96, 98, 60, 0, 0, 0, 1, 0, 0, 0, 0, 0, 132, 1, 46, 100, 114, 101, 99, 116, 118,
        101, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        10, 16, 0, 46, 100, 114, 101, 99, 116, 118, 101, 0, 0, 0, 0, 1, 0, 0, 0, 3, 0, 4, 0, 0, 0,
    ];
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let path = std::path::Path::new(&out_dir).join("msvcrt.lib");
    let mut contents = machine.to_vec();
    contents.extend_from_slice(bytes);
    std::fs::write(path, contents).unwrap();
    println!("cargo:rustc-link-search=native={out_dir}");
}
