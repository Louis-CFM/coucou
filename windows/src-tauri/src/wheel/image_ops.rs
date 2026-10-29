// The wheel's image work: convert, compress, remove metadata, one PDF from
// several images, and saving what the editor window made. Results go next to
// the original (formats::output_path); the original is never touched.

use std::io::Cursor;
use std::path::{Path, PathBuf};

use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::{CompressionType, FilterType, PngEncoder};
use image::{DynamicImage, GenericImageView, ImageFormat, ImageReader, RgbImage};

use super::formats::{ext, output_path};
use super::pdf;

fn open(path: &Path) -> Result<DynamicImage, String> {
    ImageReader::open(path)
        .map_err(|e| e.to_string())?
        .with_guessed_format()
        .map_err(|e| e.to_string())?
        .decode()
        .map_err(|e| e.to_string())
}

/// JPEG and PDF have no transparency: what was transparent turns white.
fn on_white(img: &DynamicImage) -> RgbImage {
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    let mut out = RgbImage::new(w, h);
    for (x, y, p) in rgba.enumerate_pixels() {
        let a = p[3] as u32;
        let blend = |c: u8| ((c as u32 * a + 255 * (255 - a)) / 255) as u8;
        out.put_pixel(x, y, image::Rgb([blend(p[0]), blend(p[1]), blend(p[2])]));
    }
    out
}

fn jpeg(img: &DynamicImage, quality: u8) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    let rgb = on_white(img);
    JpegEncoder::new_with_quality(&mut buf, quality).encode_image(&rgb).map_err(|e| e.to_string())?;
    Ok(buf)
}

fn png(img: &DynamicImage) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    img.write_with_encoder(PngEncoder::new_with_quality(&mut buf, CompressionType::Best, FilterType::Adaptive))
        .map_err(|e| e.to_string())?;
    Ok(buf)
}

/// The image in `format` ("jpg", "png", "webp", "tiff", "bmp", "ico", "gif").
fn encode(img: &DynamicImage, format: &str) -> Result<Vec<u8>, String> {
    let mut cursor = Cursor::new(Vec::new());
    let result = match format {
        "jpg" => return jpeg(img, 92),
        "png" => return png(img),
        "webp" => img.write_with_encoder(image::codecs::webp::WebPEncoder::new_lossless(&mut cursor)),
        // An icon is at most 256 px a side.
        "ico" => {
            let small = if img.width() > 256 || img.height() > 256 { img.thumbnail(256, 256) } else { img.clone() };
            DynamicImage::ImageRgba8(small.to_rgba8()).write_to(&mut cursor, ImageFormat::Ico)
        }
        "gif" => DynamicImage::ImageRgba8(img.to_rgba8()).write_to(&mut cursor, ImageFormat::Gif),
        "bmp" => DynamicImage::ImageRgba8(img.to_rgba8()).write_to(&mut cursor, ImageFormat::Bmp),
        "tiff" => DynamicImage::ImageRgba8(img.to_rgba8()).write_to(&mut cursor, ImageFormat::Tiff),
        other => return Err(format!("unknown format {other}")),
    };
    result.map_err(|e| e.to_string())?;
    Ok(cursor.into_inner())
}

fn write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    std::fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
}

/// Converts each image to `target`; one result per image.
pub fn convert(paths: &[PathBuf], target: &str) -> Result<Vec<PathBuf>, String> {
    let mut out = Vec::new();
    for path in paths {
        let img = open(path)?;
        let dest = output_path(path, None, target);
        if target == "pdf" {
            let page = pdf::Page { jpeg: jpeg(&img, 92)?, width: img.width(), height: img.height() };
            write(&dest, &pdf::from_pages(&[page]))?;
        } else {
            write(&dest, &encode(&img, target)?)?;
        }
        out.push(dest);
    }
    Ok(out)
}

/// All the images in one PDF, a page each, in the order given; next to the first.
pub fn merge_pdf(paths: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    let first = paths.first().ok_or("no image")?;
    let mut pages = Vec::new();
    for path in paths {
        let img = open(path)?;
        pages.push(pdf::Page { jpeg: jpeg(&img, 90)?, width: img.width(), height: img.height() });
    }
    let dest = output_path(first, Some("combined"), "pdf");
    write(&dest, &pdf::from_pages(&pages))?;
    Ok(vec![dest])
}

/// How hard to compress: the JPEG quality, and the longest side kept.
fn preset(level: &str) -> (u8, Option<u32>) {
    match level {
        "high" => (85, None),
        "small" => (55, Some(1920)),
        _ => (72, Some(3000)),
    }
}

/// Smaller files: JPEG at the preset's quality (and size); an image with
/// transparency stays a PNG, compressed as hard as PNG goes.
pub fn compress(paths: &[PathBuf], level: &str) -> Result<Vec<PathBuf>, String> {
    let (quality, max_side) = preset(level);
    let mut out = Vec::new();
    for path in paths {
        let mut img = open(path)?;
        if let Some(max) = max_side {
            if img.width() > max || img.height() > max {
                img = img.resize(max, max, image::imageops::FilterType::Lanczos3);
            }
        }
        let transparent = img.color().has_alpha() && img.to_rgba8().pixels().any(|p| p[3] < 255);
        let (bytes, format) = if transparent { (png(&img)?, "png") } else { (jpeg(&img, quality)?, "jpg") };
        let dest = output_path(path, Some("compressed"), format);
        write(&dest, &bytes)?;
        out.push(dest);
    }
    Ok(out)
}

/// A JPEG without what it says about where, when and with what it was taken:
/// APP1 (EXIF, XMP), APP13 (IPTC) and comments go, the picture is not re-encoded.
/// APP2 stays, as it holds the colour profile.
pub fn strip_jpeg(data: &[u8]) -> Option<Vec<u8>> {
    if data.len() < 4 || data[0] != 0xFF || data[1] != 0xD8 {
        return None;
    }
    let mut out = vec![0xFF, 0xD8];
    let mut i = 2;
    while i + 4 <= data.len() {
        if data[i] != 0xFF {
            return None;
        }
        let marker = data[i + 1];
        // Start of scan: the rest is the picture.
        if marker == 0xDA {
            out.extend_from_slice(&data[i..]);
            return Some(out);
        }
        let len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
        let end = i + 2 + len;
        if end > data.len() {
            return None;
        }
        if !matches!(marker, 0xE1 | 0xED | 0xFE) {
            out.extend_from_slice(&data[i..end]);
        }
        i = end;
    }
    None
}

/// A PNG without its text, EXIF and time chunks; the picture's chunks are copied as they are.
pub fn strip_png(data: &[u8]) -> Option<Vec<u8>> {
    const SIG: &[u8] = b"\x89PNG\r\n\x1a\n";
    if !data.starts_with(SIG) {
        return None;
    }
    let mut out = SIG.to_vec();
    let mut i = SIG.len();
    while i + 12 <= data.len() {
        let len = u32::from_be_bytes([data[i], data[i + 1], data[i + 2], data[i + 3]]) as usize;
        let end = i + 12 + len;
        if end > data.len() {
            return None;
        }
        let kind = &data[i + 4..i + 8];
        if !matches!(kind, b"tEXt" | b"zTXt" | b"iTXt" | b"eXIf" | b"tIME") {
            out.extend_from_slice(&data[i..end]);
        }
        i = end;
        if kind == b"IEND" {
            return Some(out);
        }
    }
    None
}

/// The same image with no metadata: JPEG and PNG losslessly, others re-encoded.
pub fn remove_metadata(paths: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    let mut out = Vec::new();
    for path in paths {
        let e = ext(path);
        let data = std::fs::read(path).map_err(|e| e.to_string())?;
        let stripped = match e.as_str() {
            "jpg" => strip_jpeg(&data),
            "png" => strip_png(&data),
            _ => None,
        };
        // The same format when Coucou writes it, else PNG.
        let format = if matches!(e.as_str(), "jpg" | "png" | "webp" | "tiff" | "bmp" | "ico" | "gif") { e.clone() } else { "png".into() };
        let bytes = match stripped {
            Some(b) => b,
            None => encode(&open(path)?, &format)?,
        };
        let dest = output_path(path, Some("no metadata"), &format);
        write(&dest, &bytes)?;
        out.push(dest);
    }
    Ok(out)
}

/// What the editor window made (a PNG data URL), saved next to the original:
/// as a JPEG when the original was one, else as a PNG.
pub fn save_edit(original: &Path, suffix: &str, data_url: &str) -> Result<PathBuf, String> {
    let png_bytes = data_url
        .strip_prefix("data:image/png;base64,")
        .and_then(crate::recap::decode_base64)
        .ok_or("not a PNG")?;
    let (bytes, format) = if ext(original) == "jpg" {
        let img = image::load_from_memory_with_format(&png_bytes, ImageFormat::Png).map_err(|e| e.to_string())?;
        (jpeg(&img, 92)?, "jpg")
    } else {
        (png_bytes, "png")
    };
    let dest = output_path(original, Some(suffix), format);
    write(&dest, &bytes)?;
    Ok(dest)
}

/// The image for the wheel's middle and the editor, at most `max` px a side, as a PNG data URL.
pub fn preview(path: &Path, max: u32) -> Option<String> {
    let img = open(path).ok()?;
    let small = if img.width() > max || img.height() > max { img.thumbnail(max, max) } else { img };
    let bytes = png(&small).ok()?;
    Some(format!("data:image/png;base64,{}", crate::claude::base64_for(&bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("coucou-img-{}-{}", std::process::id(), rand_suffix()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn rand_suffix() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64
    }

    /// A small picture with a transparent corner.
    fn sample(path: &Path) {
        let mut img = image::RgbaImage::new(40, 30);
        for (x, y, p) in img.enumerate_pixels_mut() {
            *p = image::Rgba([x as u8 * 6, y as u8 * 8, 120, if x < 5 && y < 5 { 0 } else { 255 }]);
        }
        img.save(path).unwrap();
    }

    #[test]
    fn converts_to_every_format_and_reads_back() {
        let d = dir();
        let src = d.join("tree.png");
        sample(&src);
        for target in ["jpg", "webp", "tiff", "bmp", "ico", "gif"] {
            let out = convert(&[src.clone()], target).unwrap();
            assert_eq!(ext(&out[0]), target);
            let back = image::open(&out[0]).unwrap_or_else(|e| panic!("{target}: {e}"));
            assert_eq!((back.width(), back.height()), (40, 30), "{target}");
        }
        let pdf_out = convert(&[src.clone()], "pdf").unwrap();
        assert!(std::fs::read(&pdf_out[0]).unwrap().starts_with(b"%PDF"));
        assert!(src.exists(), "the original stays");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn compress_keeps_transparency_as_png_and_shrinks_the_rest_to_jpeg() {
        let d = dir();
        let src = d.join("tree.png");
        sample(&src);
        let out = compress(&[src.clone()], "balanced").unwrap();
        assert_eq!(ext(&out[0]), "png", "a transparent corner keeps it a PNG");
        let opaque = d.join("photo.bmp");
        image::RgbImage::from_pixel(50, 50, image::Rgb([200, 100, 50])).save(&opaque).unwrap();
        let out = compress(&[opaque.clone()], "small").unwrap();
        assert_eq!(ext(&out[0]), "jpg");
        assert!(std::fs::metadata(&out[0]).unwrap().len() < std::fs::metadata(&opaque).unwrap().len());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn jpeg_metadata_goes_without_touching_the_picture() {
        // SOI, APP1 "Exif", APP2 (colour profile), COM, SOS + data, EOI.
        let mut j = vec![0xFF, 0xD8];
        j.extend_from_slice(&[0xFF, 0xE1, 0x00, 0x08, b'E', b'x', b'i', b'f', 0, 0]);
        j.extend_from_slice(&[0xFF, 0xE2, 0x00, 0x04, 1, 2]);
        j.extend_from_slice(&[0xFF, 0xFE, 0x00, 0x05, b'h', b'i', b'!']);
        j.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x02, 9, 9, 9, 0xFF, 0xD9]);
        let s = strip_jpeg(&j).unwrap();
        assert!(!s.windows(4).any(|w| w == b"Exif"), "EXIF gone");
        assert!(!s.windows(3).any(|w| w == b"hi!"), "comment gone");
        assert!(s.windows(4).any(|w| w == [0xFF, 0xE2, 0x00, 0x04]), "colour profile kept");
        assert!(s.ends_with(&[0xFF, 0xDA, 0x00, 0x02, 9, 9, 9, 0xFF, 0xD9]), "the picture as it was");
    }

    #[test]
    fn png_metadata_goes_and_the_image_still_opens() {
        let d = dir();
        let src = d.join("tree.png");
        sample(&src);
        // Add a tEXt chunk before IEND.
        let data = std::fs::read(&src).unwrap();
        let iend = data.len() - 12;
        let text = b"Author\0Someone";
        let mut chunk = (text.len() as u32).to_be_bytes().to_vec();
        chunk.extend_from_slice(b"tEXt");
        chunk.extend_from_slice(text);
        let mut crc_input = b"tEXt".to_vec();
        crc_input.extend_from_slice(text);
        chunk.extend_from_slice(&crc32(&crc_input).to_be_bytes());
        let with_text = [&data[..iend], &chunk, &data[iend..]].concat();
        std::fs::write(&src, &with_text).unwrap();
        let out = remove_metadata(&[src.clone()]).unwrap();
        let cleaned = std::fs::read(&out[0]).unwrap();
        assert!(!cleaned.windows(6).any(|w| w == b"Author"));
        assert!(image::open(&out[0]).is_ok());
        let _ = std::fs::remove_dir_all(&d);
    }

    fn crc32(data: &[u8]) -> u32 {
        let mut crc = 0xFFFF_FFFFu32;
        for &b in data {
            crc ^= b as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
            }
        }
        !crc
    }

    #[test]
    fn several_images_become_one_pdf_with_a_page_each() {
        let d = dir();
        let (a, b) = (d.join("a.png"), d.join("b.png"));
        sample(&a);
        sample(&b);
        let out = merge_pdf(&[a, b]).unwrap();
        let text = String::from_utf8_lossy(&std::fs::read(&out[0]).unwrap()).to_string();
        assert!(text.contains("/Count 2"));
        assert!(out[0].file_name().unwrap().to_string_lossy().contains("combined"));
        let _ = std::fs::remove_dir_all(&d);
    }
}
