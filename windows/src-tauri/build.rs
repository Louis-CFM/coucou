fn main() {
    // Tauri's default manifest plus the package identity the notification
    // reader needs (app.manifest, ../identity/).
    let windows = tauri_build::WindowsAttributes::new().app_manifest(include_str!("app.manifest"));
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(windows)).expect("failed to run build script");
}
