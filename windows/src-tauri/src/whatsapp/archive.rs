// Just enough of the zip format to take GOWA's binary out of the zip it publishes: the central
// directory, stored and deflated entries, nothing else (no zip64, no encryption, no streaming).
// The zip's SHA-256 has already been checked against GOWA's own when this runs; the reader is
// still strict, because it is the only parser here that faces a downloaded file.

/// No binary Coucou unpacks is bigger than this (GOWA's are about 40 MB).
pub const MAX_ENTRY: usize = 200 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    method: u16,
    compressed: usize,
    size: usize,
    local_offset: usize,
}

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?))
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

/// The entries of the central directory, in order.
pub fn entries(zip: &[u8]) -> Option<Vec<Entry>> {
    // The end record is the last 22 bytes, plus a comment of up to 64 KB.
    let lowest = zip.len().saturating_sub(22 + 65_535);
    let end = (lowest..=zip.len().checked_sub(22)?).rev().find(|&i| u32_at(zip, i) == Some(0x0605_4b50))?;
    let count = u16_at(zip, end + 10)? as usize;
    let mut at = u32_at(zip, end + 16)? as usize;
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        if u32_at(zip, at)? != 0x0201_4b50 {
            return None;
        }
        let flags = u16_at(zip, at + 8)?;
        let method = u16_at(zip, at + 10)?;
        let compressed = u32_at(zip, at + 20)?;
        let size = u32_at(zip, at + 24)?;
        let name_len = u16_at(zip, at + 28)? as usize;
        let extra_len = u16_at(zip, at + 30)? as usize;
        let comment_len = u16_at(zip, at + 32)? as usize;
        let local_offset = u32_at(zip, at + 42)?;
        // Encrypted, or zip64 (sizes in an extra field): not GOWA's zips.
        if flags & 1 != 0 || compressed == u32::MAX || size == u32::MAX || local_offset == u32::MAX {
            return None;
        }
        let name = String::from_utf8(zip.get(at + 46..at + 46 + name_len)?.to_vec()).ok()?;
        out.push(Entry { name, method, compressed: compressed as usize, size: size as usize, local_offset: local_offset as usize });
        at += 46 + name_len + extra_len + comment_len;
    }
    Some(out)
}

/// The bytes of one entry, inflated; None when it is damaged, too big, or not stored/deflated.
pub fn read(zip: &[u8], entry: &Entry) -> Option<Vec<u8>> {
    if entry.size > MAX_ENTRY || entry.compressed > zip.len() {
        return None;
    }
    let at = entry.local_offset;
    if u32_at(zip, at)? != 0x0403_4b50 {
        return None;
    }
    let start = at + 30 + u16_at(zip, at + 26)? as usize + u16_at(zip, at + 28)? as usize;
    let raw = zip.get(start..start.checked_add(entry.compressed)?)?;
    let data = match entry.method {
        0 => raw.to_vec(),
        8 => miniz_oxide::inflate::decompress_to_vec_with_limit(raw, entry.size).ok()?,
        _ => return None,
    };
    (data.len() == entry.size).then_some(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A zip as `zip` makes it: one stored entry and one deflated entry.
    fn build(files: &[(&str, &[u8], bool)]) -> Vec<u8> {
        let mut zip = Vec::new();
        let mut central = Vec::new();
        for (name, data, deflate) in files {
            let body = if *deflate { miniz_oxide::deflate::compress_to_vec(data, 6) } else { data.to_vec() };
            let method: u16 = if *deflate { 8 } else { 0 };
            let offset = zip.len() as u32;
            zip.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
            zip.extend_from_slice(&[20, 0, 0, 0]);
            zip.extend_from_slice(&method.to_le_bytes());
            zip.extend_from_slice(&[0; 8]); // time, date, crc
            zip.extend_from_slice(&(body.len() as u32).to_le_bytes());
            zip.extend_from_slice(&(data.len() as u32).to_le_bytes());
            zip.extend_from_slice(&(name.len() as u16).to_le_bytes());
            zip.extend_from_slice(&0u16.to_le_bytes());
            zip.extend_from_slice(name.as_bytes());
            zip.extend_from_slice(&body);

            central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
            central.extend_from_slice(&[20, 3, 20, 0, 0, 0]);
            central.extend_from_slice(&method.to_le_bytes());
            central.extend_from_slice(&[0; 8]);
            central.extend_from_slice(&(body.len() as u32).to_le_bytes());
            central.extend_from_slice(&(data.len() as u32).to_le_bytes());
            central.extend_from_slice(&(name.len() as u16).to_le_bytes());
            central.extend_from_slice(&[0; 12]); // extra, comment, disk, attributes (internal + external)
            central.extend_from_slice(&offset.to_le_bytes());
            central.extend_from_slice(name.as_bytes());
        }
        let cd_offset = zip.len() as u32;
        zip.extend_from_slice(&central);
        zip.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        zip.extend_from_slice(&[0; 4]);
        zip.extend_from_slice(&(files.len() as u16).to_le_bytes());
        zip.extend_from_slice(&(files.len() as u16).to_le_bytes());
        zip.extend_from_slice(&(central.len() as u32).to_le_bytes());
        zip.extend_from_slice(&cd_offset.to_le_bytes());
        zip.extend_from_slice(&0u16.to_le_bytes());
        zip
    }

    #[test]
    fn reads_stored_and_deflated_entries() {
        let binary: Vec<u8> = (0..50_000u32).map(|i| (i % 251) as u8).collect();
        let zip = build(&[("README.md", b"hello", false), ("linux-amd64", &binary, true)]);
        let list = entries(&zip).unwrap();
        assert_eq!(list.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["README.md", "linux-amd64"]);
        assert_eq!(read(&zip, &list[0]).unwrap(), b"hello");
        assert_eq!(read(&zip, &list[1]).unwrap(), binary);
    }

    #[test]
    fn refuses_what_is_not_a_clean_zip() {
        assert_eq!(entries(b""), None);
        assert_eq!(entries(b"not a zip at all, just text"), None);
        let zip = build(&[("a", b"abcdef", true)]);
        let list = entries(&zip).unwrap();
        // Cut short.
        assert_eq!(entries(&zip[..zip.len() - 5]), None);
        // A size that lies.
        let mut lying = list[0].clone();
        lying.size = 3;
        assert_eq!(read(&zip, &lying), None);
        lying.size = MAX_ENTRY + 1;
        assert_eq!(read(&zip, &lying), None);
        // A damaged body.
        let mut broken = zip.clone();
        let start = 30 + 1;
        for b in &mut broken[start..start + 4] {
            *b ^= 0xFF;
        }
        assert_ne!(read(&broken, &list[0]).as_deref(), Some(&b"abcdef"[..]));
        // An unknown method.
        let mut other = list[0].clone();
        other.method = 12;
        assert_eq!(read(&zip, &other), None);
    }
}
