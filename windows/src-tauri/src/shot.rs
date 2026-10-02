// A screenshot area picked on the roam overlay (Shift while carrying Mochi),
// and the crop Linux needs: its screenshot tools only take the whole screen.

use serde::Deserialize;

/// Part of the overlay, as fractions of its size (0…1), so it maps onto the
/// monitor's physical pixels and onto a screenshot of it alike.
#[derive(Clone, Copy, Deserialize)]
pub struct Area {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// Crops the PNG at `path` to `area`, in place.
#[cfg_attr(windows, allow(dead_code))]
pub fn crop_png(path: &std::path::Path, area: Area) -> Result<(), String> {
    use std::io::{BufReader, BufWriter};
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut decoder = png::Decoder::new(BufReader::new(file));
    // Palette and 16-bit images come out as plain 8-bit samples.
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().map_err(|e| e.to_string())?;
    let mut pixels = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut pixels).map_err(|e| e.to_string())?;
    let (w, h) = (info.width as usize, info.height as usize);
    let bpp = info.color_type.samples();

    let x0 = ((area.x * w as f64).round() as usize).min(w - 1);
    let y0 = ((area.y * h as f64).round() as usize).min(h - 1);
    let cw = ((area.w * w as f64).round() as usize).clamp(1, w - x0);
    let ch = ((area.h * h as f64).round() as usize).clamp(1, h - y0);
    let mut out = Vec::with_capacity(cw * ch * bpp);
    for row in y0..y0 + ch {
        let start = row * info.line_size + x0 * bpp;
        out.extend_from_slice(&pixels[start..start + cw * bpp]);
    }

    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut encoder = png::Encoder::new(BufWriter::new(file), cw as u32, ch as u32);
    encoder.set_color(info.color_type);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(&out).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 4×2 RGB image cropped to its right half keeps exactly those pixels.
    #[test]
    fn crop_keeps_the_area() {
        let path = std::env::temp_dir().join("coucou-crop-test.png");
        let px: Vec<u8> = (0..4 * 2 * 3).map(|i| i as u8).collect();
        {
            let file = std::fs::File::create(&path).unwrap();
            let mut enc = png::Encoder::new(std::io::BufWriter::new(file), 4, 2);
            enc.set_color(png::ColorType::Rgb);
            enc.set_depth(png::BitDepth::Eight);
            enc.write_header().unwrap().write_image_data(&px).unwrap();
        }
        crop_png(&path, Area { x: 0.5, y: 0.0, w: 0.5, h: 1.0 }).unwrap();
        let mut reader = png::Decoder::new(std::fs::File::open(&path).unwrap()).read_info().unwrap();
        let mut out = vec![0; reader.output_buffer_size()];
        let info = reader.next_frame(&mut out).unwrap();
        let _ = std::fs::remove_file(&path);
        assert_eq!((info.width, info.height), (2, 2));
        assert_eq!(&out[..6], &px[6..12]);
        assert_eq!(&out[6..12], &px[18..24]);
    }
}
