// Announces this computer on the local network while the phone link is on, so the phone finds it by itself when
// its address changes (another Wi-Fi, a hotspot). mDNS / DNS-SD, service type `_coucou._tcp`, protocol: docs/ANDROID_LINK.md.
//
// What is announced: the computer's name (the instance name), the port, and a TXT record with the protocol version and a
// short fingerprint id (the first 16 hex characters of the certificate's SHA-256, which is public by nature: anyone who
// connects gets the certificate). NEVER the token, the pairing link, a user name or a path. The phone matches the
// service to its paired computer only by that id and still pins the full certificate, so this is a hint, not a credential.
//
// Off means silent: nothing is announced and no thread runs. The daemon is created when the announcement starts and
// shut down (after a goodbye) when it stops, so there is nothing to idle.

use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The DNS-SD service type. The phone browses for `_coucou._tcp`.
pub const SERVICE_TYPE: &str = "_coucou._tcp.local.";
/// How many hex characters of the certificate fingerprint go into the TXT record.
pub const FP_ID_LEN: usize = 16;
/// The protocol version in the TXT record (docs/ANDROID_LINK.md stays at v=1).
pub const TXT_VERSION: &str = "1";

/// The short, non-secret id of a certificate fingerprint: its first 16 lowercase hex characters. None if the input is not hex.
pub fn fingerprint_id(fingerprint: &str) -> Option<String> {
    let f = fingerprint.trim().to_ascii_lowercase();
    if f.len() < FP_ID_LEN || !f.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    Some(f[..FP_ID_LEN].to_string())
}

/// The TXT record: `v` and `fp`, nothing else.
pub fn txt(fingerprint: &str) -> Option<Vec<(String, String)>> {
    let id = fingerprint_id(fingerprint)?;
    Some(vec![("v".to_string(), TXT_VERSION.to_string()), ("fp".to_string(), id)])
}

/// A DNS host label from the computer's name: ASCII letters, digits and hyphens, at most 63, "coucou" if nothing is left.
pub fn host_label(name: &str) -> String {
    let mut label: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .chars()
        .take(63)
        .collect();
    if label.is_empty() {
        label = "coucou".to_string();
    }
    label
}

/// What is announced for one computer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Advert {
    pub instance: String,
    pub host: String,
    pub port: u16,
    pub txt: Vec<(String, String)>,
}

pub fn advert(name: &str, port: u16, fingerprint: &str) -> Option<Advert> {
    let instance: String = name.trim().chars().take(48).collect();
    let instance = instance.trim().to_string();
    Some(Advert {
        instance: if instance.is_empty() { "Coucou".to_string() } else { instance },
        host: format!("{}.local.", host_label(name)),
        port,
        txt: txt(fingerprint)?,
    })
}

/// Where announcements go: the network in the app, a recorder in tests.
pub trait Publisher: Send + Sync {
    fn publish(&self, advert: &Advert) -> Result<(), String>;
    fn withdraw(&self, advert: &Advert);
}

/// Starts and stops the announcement with the phone link.
pub struct Advertiser {
    publisher: Arc<dyn Publisher>,
    current: Mutex<Option<Advert>>,
}

impl Advertiser {
    pub fn new(publisher: Arc<dyn Publisher>) -> Self {
        Self { publisher, current: Mutex::new(None) }
    }

    /// Announces the computer. A failure is returned for the log and changes nothing else: the link works without it
    /// (the phone still has the saved address).
    pub fn start(&self, name: &str, port: u16, fingerprint: &str) -> Result<(), String> {
        let ad = advert(name, port, fingerprint).ok_or("the certificate fingerprint is not valid")?;
        let mut cur = self.current.lock().unwrap();
        if let Some(old) = cur.take() {
            self.publisher.withdraw(&old);
        }
        self.publisher.publish(&ad)?;
        *cur = Some(ad);
        Ok(())
    }

    /// Withdraws the announcement (switch off, link stopped, app quitting). Safe to call when nothing is announced.
    pub fn stop(&self) {
        if let Some(ad) = self.current.lock().unwrap().take() {
            self.publisher.withdraw(&ad);
        }
    }

    #[cfg(test)]
    pub fn is_advertising(&self) -> bool {
        self.current.lock().unwrap().is_some()
    }
}

/// The real thing: mdns-sd. A daemon exists only between `publish` and `withdraw`.
pub struct MdnsPublisher {
    daemon: Mutex<Option<mdns_sd::ServiceDaemon>>,
}

impl MdnsPublisher {
    pub fn new() -> Self {
        Self { daemon: Mutex::new(None) }
    }
}

impl Publisher for MdnsPublisher {
    fn publish(&self, ad: &Advert) -> Result<(), String> {
        use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};
        let daemon = ServiceDaemon::new().map_err(|e| e.to_string())?;
        // The server listens on IPv4 only; announcing an IPv6 address would send the phone to a dead end.
        let _ = daemon.disable_interface(IfKind::IPv6);
        let info = ServiceInfo::new(SERVICE_TYPE, &ad.instance, &ad.host, "", ad.port, ad.txt.as_slice())
            .map_err(|e| e.to_string())?
            .enable_addr_auto();
        if let Err(e) = daemon.register(info) {
            let _ = daemon.shutdown();
            return Err(e.to_string());
        }
        *self.daemon.lock().unwrap() = Some(daemon);
        Ok(())
    }

    fn withdraw(&self, ad: &Advert) {
        let Some(daemon) = self.daemon.lock().unwrap().take() else { return };
        let fullname = format!("{}.{}", ad.instance, SERVICE_TYPE);
        // A goodbye packet lets phones forget the service at once; then the daemon thread ends.
        if let Ok(done) = daemon.unregister(&fullname) {
            let _ = done.recv_timeout(Duration::from_millis(500));
        }
        if let Ok(done) = daemon.shutdown() {
            let _ = done.recv_timeout(Duration::from_millis(500));
        }
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    const FP: &str = "AB12CD34EF56AB78901234567890abcdef1234567890abcdef1234567890abcd";
    const TOKEN: &str = "tok_ABCDEFGHIJKLMNOP1234";

    #[derive(Default)]
    pub struct Recorder {
        pub log: Mutex<Vec<String>>,
        pub fail: Mutex<bool>,
    }

    impl Publisher for Recorder {
        fn publish(&self, ad: &Advert) -> Result<(), String> {
            if *self.fail.lock().unwrap() {
                return Err("no network".into());
            }
            self.log.lock().unwrap().push(format!("publish {} {} {:?}", ad.instance, ad.port, ad.txt));
            Ok(())
        }
        fn withdraw(&self, ad: &Advert) {
            self.log.lock().unwrap().push(format!("withdraw {}", ad.instance));
        }
    }

    #[test]
    fn the_id_is_the_first_sixteen_hex_characters_in_lowercase() {
        assert_eq!(fingerprint_id(FP).as_deref(), Some("ab12cd34ef56ab78"));
        assert_eq!(fingerprint_id(&FP.to_lowercase()).as_deref(), Some("ab12cd34ef56ab78"));
        assert_eq!(FP_ID_LEN, 16);
    }

    #[test]
    fn a_fingerprint_that_is_not_hex_or_too_short_gives_no_id() {
        assert_eq!(fingerprint_id("zz12cd34ef56ab78901234"), None);
        assert_eq!(fingerprint_id("abcd"), None);
        assert_eq!(fingerprint_id(""), None);
    }

    #[test]
    fn the_txt_record_is_the_version_and_the_id_and_nothing_else() {
        let t = txt(FP).unwrap();
        assert_eq!(t, vec![("v".to_string(), "1".to_string()), ("fp".to_string(), "ab12cd34ef56ab78".to_string())]);
    }

    #[test]
    fn nothing_secret_can_reach_the_announcement() {
        // The announcement is built from the name, the port and the fingerprint only: the token and the link are
        // not even inputs. Check the output anyway, as the rule is what matters.
        let ad = advert("Rhytam-PC", 47821, FP).unwrap();
        let everything = format!("{:?}", ad).to_lowercase();
        for secret in [TOKEN.to_lowercase(), "coucou://".to_string(), "token".to_string(), "password".to_string()] {
            assert!(!everything.contains(&secret), "announcement contains {secret}");
        }
        // The full certificate fingerprint is not in it either, only the short id.
        assert!(!everything.contains(&FP.to_lowercase()));
        assert!(ad.txt.iter().all(|(k, v)| (k == "v" || k == "fp") && v.len() <= FP_ID_LEN));
        assert!(!ad.instance.contains('/') && !ad.instance.contains('\\'), "no path");
    }

    #[test]
    fn the_instance_is_the_computer_name_and_the_host_a_valid_label() {
        let ad = advert("Rhytam's PC", 47821, FP).unwrap();
        assert_eq!(ad.instance, "Rhytam's PC");
        assert_eq!(ad.host, "Rhytam-s-PC.local.");
        assert_eq!(ad.port, 47821);
        assert_eq!(host_label("***"), "coucou");
        assert_eq!(host_label(&"a".repeat(100)).len(), 63);
        assert_eq!(advert("   ", 1, FP).unwrap().instance, "Coucou");
    }

    #[test]
    fn it_is_announced_on_start_and_withdrawn_on_stop() {
        let rec = Arc::new(Recorder::default());
        let adv = Advertiser::new(rec.clone());
        assert!(!adv.is_advertising());
        adv.start("PC", 47821, FP).unwrap();
        assert!(adv.is_advertising());
        adv.stop();
        assert!(!adv.is_advertising());
        adv.stop(); // nothing more to withdraw
        let log = rec.log.lock().unwrap();
        assert_eq!(log.len(), 2);
        assert!(log[0].starts_with("publish PC 47821"));
        assert_eq!(log[1], "withdraw PC");
    }

    #[test]
    fn announcing_again_replaces_the_old_announcement() {
        let rec = Arc::new(Recorder::default());
        let adv = Advertiser::new(rec.clone());
        adv.start("PC", 47821, FP).unwrap();
        adv.start("PC", 47822, FP).unwrap();
        let log = rec.log.lock().unwrap().clone();
        assert_eq!(log.iter().filter(|l| l.starts_with("withdraw")).count(), 1);
        assert!(log.last().unwrap().contains("47822"));
    }

    #[test]
    fn a_failing_network_is_an_error_not_a_crash_and_leaves_nothing_announced() {
        let rec = Arc::new(Recorder::default());
        *rec.fail.lock().unwrap() = true;
        let adv = Advertiser::new(rec.clone());
        assert!(adv.start("PC", 47821, FP).is_err());
        assert!(!adv.is_advertising());
        assert!(adv.start("PC", 47821, "not a fingerprint").is_err());
    }

    #[test]
    fn nothing_is_announced_before_start() {
        let rec = Arc::new(Recorder::default());
        let _adv = Advertiser::new(rec.clone());
        assert!(rec.log.lock().unwrap().is_empty());
    }
}
