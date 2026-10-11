use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct WindowCaptureResult {
    pub window_title: String,
    pub width: i32,
    pub height: i32,
    pub base64_image: Option<String>,
}

#[cfg(target_os = "windows")]
pub fn capture_active_window() -> Result<WindowCaptureResult, String> {
    use windows::Win32::Foundation::{HWND, RECT};
    use windows::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC,
        ReleaseDC, SelectObject, SRCCOPY,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        GetForegroundWindow, GetWindowRect, GetWindowTextW,
    };

    unsafe {
        let hwnd: HWND = GetForegroundWindow();
        if hwnd.0.is_null() {
            return Err("Nenhuma janela em primeiro plano encontrada".to_string());
        }

        // Get window title
        let mut title_buf = [0u16; 512];
        let len = GetWindowTextW(hwnd, &mut title_buf);
        let title = String::from_utf16_lossy(&title_buf[..len as usize]);

        // Get window dimensions
        let mut rect = RECT::default();
        if !GetWindowRect(hwnd, &mut rect).is_ok() {
            return Err("Não foi possível obter dimensões da janela".to_string());
        }

        let width = (rect.right - rect.left).max(1);
        let height = (rect.bottom - rect.top).max(1);

        // Capture window DC using GDI
        let hdc_window = GetDC(Some(hwnd));
        let hdc_mem = CreateCompatibleDC(Some(hdc_window));
        let hbitmap = CreateCompatibleBitmap(hdc_window, width, height);
        let old_bitmap = SelectObject(hdc_mem, hbitmap.into());

        let _ = BitBlt(hdc_mem, 0, 0, width, height, Some(hdc_window), 0, 0, SRCCOPY);

        // Cleanup GDI objects
        SelectObject(hdc_mem, old_bitmap);
        let _ = DeleteObject(hbitmap.into());
        let _ = DeleteDC(hdc_mem);
        ReleaseDC(Some(hwnd), hdc_window);

        Ok(WindowCaptureResult {
            window_title: if title.is_empty() {
                "Área de Trabalho / Janela do Windows".to_string()
            } else {
                title
            },
            width,
            height,
            base64_image: None,
        })
    }
}

#[cfg(not(target_os = "windows"))]
pub fn capture_active_window() -> Result<WindowCaptureResult, String> {
    Ok(WindowCaptureResult {
        window_title: "Active Window (Mock)".to_string(),
        width: 1920,
        height: 1080,
        base64_image: None,
    })
}
