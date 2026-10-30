// The wheel's liquid glass: a picture of the screen where the wheel is about to
// open, taken just before it shows (the window is still off the screen), that
// its page refracts behind the disc. Lightly blurred here (a CSS blur fades
// the picture's edges to nothing), as a JPEG data URL, in memory only; and
// whether it is dark, so the wheel's labels turn light over it.

pub struct Behind {
    pub picture: String,
    pub dark: bool,
}

/// Dark enough for light labels: the mean luma (0..255) below the middle.
pub fn is_dark(rgb: &image::RgbImage) -> bool {
    let n = (rgb.width() as u64 * rgb.height() as u64).max(1);
    let sum: u64 = rgb.pixels().map(|p| (299 * p[0] as u64 + 587 * p[1] as u64 + 114 * p[2] as u64) / 1000).sum();
    sum / n < 128
}

#[cfg(windows)]
pub fn behind(x: i32, y: i32, w: i32, h: i32) -> Option<Behind> {
    use windows::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC, SelectObject,
        BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, SRCCOPY,
    };
    if w <= 0 || h <= 0 {
        return None;
    }
    let mut bgra = vec![0u8; (w * h * 4) as usize];
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let bitmap = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(mem, bitmap.into());
        let copied = BitBlt(mem, 0, 0, w, h, Some(screen), x, y, SRCCOPY).is_ok();
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let lines = GetDIBits(mem, bitmap, 0, h as u32, Some(bgra.as_mut_ptr().cast()), &mut info, DIB_RGB_COLORS);
        SelectObject(mem, old);
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if !copied || lines == 0 {
            return None;
        }
    }
    let mut rgb = image::RgbImage::new(w as u32, h as u32);
    for (i, px) in rgb.pixels_mut().enumerate() {
        let o = i * 4;
        *px = image::Rgb([bgra[o + 2], bgra[o + 1], bgra[o]]);
    }
    // Liquid glass keeps the world behind it nearly sharp: a light blur, and
    // the page bends it at the edges (wheel/lens.ts).
    let blurred = image::imageops::blur(&rgb, 1.6);
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 85).encode_image(&blurred).ok()?;
    Some(Behind {
        picture: format!("data:image/jpeg;base64,{}", crate::claude::base64_for(&jpeg)),
        dark: is_dark(&blurred),
    })
}

#[cfg(not(windows))]
pub fn behind(_x: i32, _y: i32, _w: i32, _h: i32) -> Option<Behind> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dark_and_light_screens() {
        assert!(is_dark(&image::RgbImage::from_pixel(4, 4, image::Rgb([30, 30, 32]))));
        assert!(!is_dark(&image::RgbImage::from_pixel(4, 4, image::Rgb([240, 240, 235]))));
    }
}
