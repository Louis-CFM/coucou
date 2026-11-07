// A PDF from images: one page per image, each the image's own size (at 96 dpi),
// the picture embedded as JPEG. Enough PDF for that, written by hand.

/// One page: a JPEG and its size in pixels.
pub struct Page {
    pub jpeg: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

pub fn from_pages(pages: &[Page]) -> Vec<u8> {
    let mut out: Vec<u8> = b"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".to_vec();
    let mut offsets: Vec<usize> = Vec::new();
    // Objects: 1 catalog, 2 pages, then per page: page, content, image.
    let page_ids: Vec<usize> = (0..pages.len()).map(|i| 3 + i * 3).collect();
    let mut objects: Vec<Vec<u8>> = Vec::new();
    objects.push(b"<< /Type /Catalog /Pages 2 0 R >>".to_vec());
    let kids = page_ids.iter().map(|id| format!("{id} 0 R")).collect::<Vec<_>>().join(" ");
    objects.push(format!("<< /Type /Pages /Kids [{kids}] /Count {} >>", pages.len()).into_bytes());
    for (i, page) in pages.iter().enumerate() {
        let id = page_ids[i];
        // 96 dpi pixels to 72 dpi points.
        let (w, h) = (page.width as f64 * 0.75, page.height as f64 * 0.75);
        objects.push(
            format!(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w:.2} {h:.2}] /Resources << /XObject << /Im{i} {} 0 R >> >> /Contents {} 0 R >>",
                id + 2,
                id + 1
            )
            .into_bytes(),
        );
        let content = format!("q {w:.2} 0 0 {h:.2} 0 0 cm /Im{i} Do Q");
        objects.push(format!("<< /Length {} >>\nstream\n{content}\nendstream", content.len()).into_bytes());
        let mut image = format!(
            "<< /Type /XObject /Subtype /Image /Width {} /Height {} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {} >>\nstream\n",
            page.width,
            page.height,
            page.jpeg.len()
        )
        .into_bytes();
        image.extend_from_slice(&page.jpeg);
        image.extend_from_slice(b"\nendstream");
        objects.push(image);
    }
    for (n, body) in objects.iter().enumerate() {
        offsets.push(out.len());
        out.extend_from_slice(format!("{} 0 obj\n", n + 1).as_bytes());
        out.extend_from_slice(body);
        out.extend_from_slice(b"\nendobj\n");
    }
    let xref = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes());
    for o in &offsets {
        out.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n", objects.len() + 1).as_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_page_per_image_with_a_cross_reference_that_points_at_each_object() {
        let pdf = from_pages(&[
            Page { jpeg: vec![0xFF, 0xD8, 1, 2, 0xFF, 0xD9], width: 400, height: 300 },
            Page { jpeg: vec![0xFF, 0xD8, 3, 0xFF, 0xD9], width: 200, height: 200 },
        ]);
        let text = String::from_utf8_lossy(&pdf);
        assert!(text.starts_with("%PDF-1.4"));
        assert!(text.contains("/Count 2"));
        assert!(text.contains("/MediaBox [0 0 300.00 225.00]"), "400 × 300 px at 96 dpi");
        // Every xref entry is the offset of "N 0 obj".
        let xref_at = text.rfind("xref\n").unwrap();
        for (n, line) in text[xref_at..].lines().skip(3).take(8).enumerate() {
            let offset: usize = line[..10].parse().unwrap();
            assert!(text[offset..].starts_with(&format!("{} 0 obj", n + 1)), "object {}", n + 1);
        }
        assert!(text.trim_end().ends_with("%%EOF"));
    }
}
