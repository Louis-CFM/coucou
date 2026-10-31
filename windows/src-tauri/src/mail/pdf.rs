// A PDF cut into one-page files, with each page's text: what the mail merge needs to give
// each recipient their page (the Mac does this with PDFKit). lopdf, pure Rust, MIT.

use std::path::{Path, PathBuf};

pub struct Pages {
    /// One file per page, in order.
    pub files: Vec<PathBuf>,
    /// The text of each page ("" for a scanned page, which has none).
    pub texts: Vec<String>,
}

/// Cuts `pdf` into `dir/p1.pdf`, `dir/p2.pdf`…
pub fn split(pdf: &Path, dir: &Path) -> Result<Pages, String> {
    let doc = lopdf::Document::load(pdf).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let numbers: Vec<u32> = doc.get_pages().keys().copied().collect();
    let mut files = Vec::new();
    let mut texts = Vec::new();
    for &n in &numbers {
        texts.push(doc.extract_text(&[n]).unwrap_or_default());
        let mut single = doc.clone();
        let others: Vec<u32> = numbers.iter().copied().filter(|&m| m != n).collect();
        single.delete_pages(&others);
        single.prune_objects();
        let path = dir.join(format!("p{n}.pdf"));
        single.save(&path).map_err(|e| e.to_string())?;
        files.push(path);
    }
    Ok(Pages { files, texts })
}

#[cfg(test)]
mod tests {
    use super::*;
    use lopdf::content::{Content, Operation};
    use lopdf::{dictionary, Document, Object, Stream};

    /// A PDF with one line of text per page.
    fn sample(lines: &[&str], path: &Path) {
        let mut doc = Document::with_version("1.5");
        let pages_id = doc.new_object_id();
        let font_id = doc.add_object(dictionary! {
            "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica",
        });
        let resources_id = doc.add_object(dictionary! { "Font" => dictionary! { "F1" => font_id } });
        let mut kids = Vec::new();
        for line in lines {
            let content = Content {
                operations: vec![
                    Operation::new("BT", vec![]),
                    Operation::new("Tf", vec!["F1".into(), 24.into()]),
                    Operation::new("Td", vec![100.into(), 600.into()]),
                    Operation::new("Tj", vec![Object::string_literal(*line)]),
                    Operation::new("ET", vec![]),
                ],
            };
            let content_id = doc.add_object(Stream::new(dictionary! {}, content.encode().unwrap()));
            let page_id = doc.add_object(dictionary! {
                "Type" => "Page", "Parent" => pages_id, "Contents" => content_id,
                "Resources" => resources_id, "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
            });
            kids.push(page_id.into());
        }
        let count = kids.len() as i64;
        doc.objects.insert(pages_id, Object::Dictionary(dictionary! { "Type" => "Pages", "Kids" => kids, "Count" => count }));
        let catalog_id = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
        doc.trailer.set("Root", catalog_id);
        doc.save(path).unwrap();
    }

    #[test]
    fn a_pdf_is_cut_into_pages_with_their_text() {
        let dir = std::env::temp_dir().join(format!("coucou-pdf-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("plans.pdf");
        sample(&["Plan Bordeaux", "Plan Lyon", "Plan Nice"], &source);
        let pages = split(&source, &dir.join("out")).unwrap();
        assert_eq!(pages.files.len(), 3);
        assert!(pages.texts[1].contains("Lyon"), "{:?}", pages.texts);
        let one = lopdf::Document::load(&pages.files[2]).unwrap();
        assert_eq!(one.get_pages().len(), 1);
        assert!(one.extract_text(&[1]).unwrap().contains("Nice"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
