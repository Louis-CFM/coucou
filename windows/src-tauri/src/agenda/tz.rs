// Outlook writes a time zone as a Windows name ("Romance Standard Time"), which chrono-tz does not
// know. This is the Unicode CLDR table (windowsZones.xml, the default zone of each name), enough
// for the names Outlook and Exchange write. A name that is not here falls back to the user's own
// zone, see ics.rs.

use chrono_tz::Tz;

/// The zone a TZID names: an IANA name as is, or a Windows name through the table.
pub fn resolve(tzid: &str) -> Option<Tz> {
    let tzid = tzid.trim().trim_matches('"');
    if let Ok(tz) = tzid.parse::<Tz>() {
        return Some(tz);
    }
    let iana = WINDOWS
        .iter()
        .find(|(windows, _)| windows.eq_ignore_ascii_case(tzid))
        .map(|(_, iana)| *iana)?;
    iana.parse::<Tz>().ok()
}

const WINDOWS: &[(&str, &str)] = &[
    ("UTC", "UTC"),
    ("GMT Standard Time", "Europe/London"),
    ("Greenwich Standard Time", "Atlantic/Reykjavik"),
    ("W. Europe Standard Time", "Europe/Berlin"),
    ("Central Europe Standard Time", "Europe/Budapest"),
    ("Romance Standard Time", "Europe/Paris"),
    ("Central European Standard Time", "Europe/Warsaw"),
    ("W. Central Africa Standard Time", "Africa/Lagos"),
    ("GTB Standard Time", "Europe/Bucharest"),
    ("E. Europe Standard Time", "Europe/Chisinau"),
    ("FLE Standard Time", "Europe/Kiev"),
    ("Russian Standard Time", "Europe/Moscow"),
    ("Turkey Standard Time", "Europe/Istanbul"),
    ("Israel Standard Time", "Asia/Jerusalem"),
    ("Egypt Standard Time", "Africa/Cairo"),
    ("South Africa Standard Time", "Africa/Johannesburg"),
    ("Morocco Standard Time", "Africa/Casablanca"),
    ("E. Africa Standard Time", "Africa/Nairobi"),
    ("Arab Standard Time", "Asia/Riyadh"),
    ("Arabian Standard Time", "Asia/Dubai"),
    ("Iran Standard Time", "Asia/Tehran"),
    ("Pakistan Standard Time", "Asia/Karachi"),
    ("India Standard Time", "Asia/Calcutta"),
    ("Bangladesh Standard Time", "Asia/Dhaka"),
    ("SE Asia Standard Time", "Asia/Bangkok"),
    ("China Standard Time", "Asia/Shanghai"),
    ("Singapore Standard Time", "Asia/Singapore"),
    ("W. Australia Standard Time", "Australia/Perth"),
    ("Taipei Standard Time", "Asia/Taipei"),
    ("Tokyo Standard Time", "Asia/Tokyo"),
    ("Korea Standard Time", "Asia/Seoul"),
    ("AUS Eastern Standard Time", "Australia/Sydney"),
    ("E. Australia Standard Time", "Australia/Brisbane"),
    ("New Zealand Standard Time", "Pacific/Auckland"),
    ("Hawaiian Standard Time", "Pacific/Honolulu"),
    ("Alaskan Standard Time", "America/Anchorage"),
    ("Pacific Standard Time", "America/Los_Angeles"),
    ("Mountain Standard Time", "America/Denver"),
    ("US Mountain Standard Time", "America/Phoenix"),
    ("Central Standard Time", "America/Chicago"),
    ("Eastern Standard Time", "America/New_York"),
    ("US Eastern Standard Time", "America/Indianapolis"),
    ("Canada Central Standard Time", "America/Regina"),
    ("Atlantic Standard Time", "America/Halifax"),
    ("Newfoundland Standard Time", "America/St_Johns"),
    ("Mexico Standard Time", "America/Mexico_City"),
    ("SA Pacific Standard Time", "America/Bogota"),
    ("SA Western Standard Time", "America/La_Paz"),
    ("SA Eastern Standard Time", "America/Cayenne"),
    ("E. South America Standard Time", "America/Sao_Paulo"),
    ("Argentina Standard Time", "America/Buenos_Aires"),
    ("Pacific SA Standard Time", "America/Santiago"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_iana_name_passes_and_a_windows_name_is_translated() {
        assert_eq!(resolve("Europe/Paris"), Some(Tz::Europe__Paris));
        assert_eq!(resolve("Romance Standard Time"), Some(Tz::Europe__Paris));
        assert_eq!(resolve("\"Romance Standard Time\""), Some(Tz::Europe__Paris));
        assert_eq!(resolve("romance standard time"), Some(Tz::Europe__Paris));
        assert_eq!(resolve("Atlantis Standard Time"), None);
    }

    #[test]
    fn every_name_in_the_table_is_a_zone_chrono_knows() {
        for (windows, iana) in WINDOWS {
            assert!(iana.parse::<Tz>().is_ok(), "{windows} -> {iana}");
        }
    }
}
