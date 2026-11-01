//! When the radio runs, and what the last run says about this firmware. No hardware here.
//!
//! The kernel's first IBSS vdev on this firmware has never run [U]. A firmware assert stops the modem until the next boot: Wi-Fi and cellular, not only AWDL (TopazModem.cpp modem_watch has no
//! restart). CLAUDE.md: a failure turns off only that feature. So a step of the radio that has never run on this firmware does not run by itself: the owner allows it, once, in a
//! file (`allow`). The state file holds what was tried: `trying-*` is written before the start; a boot that finds it, or a modem crash while the vdev is on or just after, stops the feature for
//! good (`failed`). What has run well (`alone-ok`, `shared-ok`) runs on by itself. To try again after a failure: `rm /private/var/db/laurel-awdl.state`.

/// The file's states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Proof {
    None,
    TryingAlone,
    AloneOk,
    TryingShared,
    SharedOk,
    /// The modem stopped while the vdev was on, or just after: never again by itself.
    Failed,
}

/// What the owner allows that has not yet run on this firmware. File: `alone` or `shared`. No file: nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Allow {
    Nothing,
    Alone,
    Shared,
}

impl Allow {
    pub fn parse(text: &str) -> Allow {
        match text.trim() {
            "alone" => Allow::Alone,
            "shared" => Allow::Shared,
            _ => Allow::Nothing,
        }
    }
}

impl Proof {
    pub fn parse(text: &str) -> Proof {
        match text.trim() {
            "trying-alone" => Proof::TryingAlone,
            "alone-ok" => Proof::AloneOk,
            "trying-shared" => Proof::TryingShared,
            "shared-ok" => Proof::SharedOk,
            "failed" => Proof::Failed,
            _ => Proof::None,
        }
    }

    pub fn word(self) -> &'static str {
        match self {
            Proof::None => "",
            Proof::TryingAlone => "trying-alone",
            Proof::AloneOk => "alone-ok",
            Proof::TryingShared => "trying-shared",
            Proof::SharedOk => "shared-ok",
            Proof::Failed => "failed",
        }
    }

    /// At boot: the last start did not get as far as its proof, or the modem stopped under it.
    pub fn unfinished(self) -> bool {
        matches!(self, Proof::TryingAlone | Proof::TryingShared | Proof::Failed)
    }
}

/// How long AirDrop's Bluetooth advertisement keeps the radio on, in s.
pub const BLE_LINGER_S: u32 = 120;
/// The time a start must live for its proof, in s.
pub const PROOF_S: u64 = 10;
/// The time on one channel with no AWDL frame, in s, before the next channel. A Fixed radio only.
pub const NO_PEER_ROTATE_S: u64 = 20;

/// The time en0 must be idle before the cell may start alone, in s: at boot en0 is idle for a moment before wifid joins, and a join must not find the cell in its way.
pub const EN0_SETTLE_S: u64 = 30;
/// A modem crash this soon after the vdev ended counts as the vdev's, in ms (the firmware asserts at a teardown too).
pub const BLAME_MS: u32 = 10_000;

/// Is a modem stop the fault of this radio? `state` freezes when the modem thread ends. `off_age_ms`: as the kernel's status.
pub fn modem_stop_is_ours(state: u32, off_age_ms: u32) -> bool {
    state != 0 || off_age_ms < BLAME_MS
}

/// iOS 26: awdl0 must be typed as Apple's, and made before sharingd looks for it (docs/laurel_sprout/ios26-airdrop.md). iOS 16: as before. `kern.osrelease`: "25.5.0" on iOS 26, "22.6.0" on iOS 16.
pub fn typed_awdl0(osrelease: &str) -> bool {
    osrelease.split('.').next().and_then(|m| m.parse::<u32>().ok()).is_some_and(|m| m >= 25)
}

/// sharingd's mode in its preference file: `DiscoverableMode` of a binary plist (cfprefsd writes binary). Not a search for "Everyone": both iOS 16 and 26 keep a key
/// `EveryoneModeUpdateTime` after the mode has ended [V sharingd 20H392, 23F84], and the radio would then run for ever.
pub fn discoverable_mode(plist: &[u8]) -> Option<String> {
    let n = plist.len();
    if n < 40 || &plist[..8] != b"bplist00" {
        return None;
    }
    let t = &plist[n - 32..];
    let off_size = t[6] as usize;
    let ref_size = t[7] as usize;
    let count = usize::try_from(u64::from_be_bytes(t[8..16].try_into().ok()?)).ok()?;
    let top = usize::try_from(u64::from_be_bytes(t[16..24].try_into().ok()?)).ok()?;
    let table = usize::try_from(u64::from_be_bytes(t[24..32].try_into().ok()?)).ok()?;
    if !(1..=8).contains(&off_size) || !(1..=8).contains(&ref_size) || top >= count {
        return None;
    }
    let num = |at: usize, size: usize| -> Option<usize> {
        let b = plist.get(at..at.checked_add(size)?)?;
        Some(b.iter().fold(0usize, |v, x| (v << 8) | usize::from(*x)))
    };
    let object = |i: usize| -> Option<usize> { num(table.checked_add(i.checked_mul(off_size)?)?, off_size) };
    // an object's marker and its length, with the long form (low nibble 15: then an integer object)
    let head = |at: usize| -> Option<(u8, usize, usize)> {
        let m = *plist.get(at)?;
        let low = usize::from(m & 15);
        if low != 15 {
            return Some((m >> 4, low, at + 1));
        }
        let l = *plist.get(at + 1)?;
        if l >> 4 != 1 {
            return None;
        }
        let size = 1usize << (l & 15);
        Some((m >> 4, num(at + 2, size)?, at + 2 + size))
    };
    let string = |at: usize| -> Option<String> {
        let (kind, len, body) = head(at)?;
        match kind {
            5 => plist.get(body..body.checked_add(len)?).map(|b| String::from_utf8_lossy(b).into_owned()),
            6 => {
                let b = plist.get(body..body.checked_add(len.checked_mul(2)?)?)?;
                Some(String::from_utf16_lossy(&b.chunks_exact(2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect::<Vec<_>>()))
            }
            _ => None,
        }
    };
    let (kind, pairs, body) = head(object(top)?)?;
    if kind != 13 {
        return None;
    }
    for i in 0..pairs {
        let key = num(body.checked_add(i.checked_mul(ref_size)?)?, ref_size)?;
        if string(object(key)?)?.as_str() == "DiscoverableMode" {
            let value = num(body.checked_add((pairs + i).checked_mul(ref_size)?)?, ref_size)?;
            return string(object(value)?);
        }
    }
    None
}

/// Does sharingd's preference file say Everyone?
pub fn everyone(plist: &[u8]) -> bool {
    discoverable_mode(plist).as_deref() == Some("Everyone")
}

pub fn wanted(everyone: bool, ble_age_s: u32) -> bool {
    everyone || ble_age_s < BLE_LINGER_S
}

/// AWDL's social channels, in the order that Owly tries them: an iPhone gives channel 6 a slot or two in sixteen, 44 or 149 several.
pub const CHANNELS: [u16; 3] = [5220, 5745, 2437];

/// Why nothing starts until the owner allows it. These lines say what a failure costs.
pub const GATE_ALONE: &str = "the IBSS vdev has never run on this firmware; a firmware assert would stop the modem (Wi-Fi and cellular) until the next boot: `echo alone > /private/var/db/laurel-awdl.allow` allows one try";
pub const GATE_SHARED: &str = "the cell beside a joined en0 has never run on this firmware; a firmware assert would stop the modem (Wi-Fi and cellular) until the next boot: `echo shared > /private/var/db/laurel-awdl.allow` allows one try";

/// What to do with en0 as it is. `Some(freq, share)`: start there. `None` with the text: wait, for that reason.
pub fn pick(en0_state: u32, en0_freq: u32, next_alone: u16, proof: Proof, allow: Allow, en0_idle_s: u64) -> Result<(u16, bool), &'static str> {
    match en0_state {
        1 => Err("en0 is joining"),
        2 => {
            if !CHANNELS.iter().any(|&c| u32::from(c) == en0_freq) {
                Err("en0 is joined on a channel that AWDL does not use (AWDL needs 6, 44 or 149), and only one channel is possible")
            } else {
                match proof {
                    Proof::SharedOk => Ok((en0_freq as u16, true)),
                    Proof::AloneOk if allow == Allow::Shared => Ok((en0_freq as u16, true)),
                    Proof::AloneOk => Err(GATE_SHARED),
                    _ => Err("the cell must run once with en0 not joined before it runs beside en0"),
                }
            }
        }
        _ if en0_idle_s < EN0_SETTLE_S => Err("en0 may join soon: waiting"),
        _ => match proof {
            Proof::None if allow == Allow::Nothing => Err(GATE_ALONE),
            Proof::Failed | Proof::TryingAlone | Proof::TryingShared => Err("the last start did not finish"),
            _ => Ok((next_alone, false)),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proof_words_round_trip() {
        for p in [Proof::TryingAlone, Proof::AloneOk, Proof::TryingShared, Proof::SharedOk, Proof::Failed] {
            assert_eq!(Proof::parse(p.word()), p);
        }
        assert_eq!(Proof::parse("junk\n"), Proof::None);
        assert!(Proof::TryingAlone.unfinished() && Proof::TryingShared.unfinished() && Proof::Failed.unfinished());
        assert!(!Proof::AloneOk.unfinished() && !Proof::None.unfinished());
    }

    // made by plistlib: {'DiscoverableMode': mode, 'EveryoneModeUpdateTime': 1.0} (scripts/laurel/awdl-plist-vectors.py)
    const EVERYONE: &[u8] = include_bytes!("../tests/plist-everyone.bplist");
    const CONTACTS: &[u8] = include_bytes!("../tests/plist-contacts-after-everyone.bplist");
    const LONG_FIRST: &[u8] = include_bytes!("../tests/plist-long-keys.bplist");

    #[test]
    fn everyone_in_a_plist() {
        assert_eq!(discoverable_mode(EVERYONE).as_deref(), Some("Everyone"));
        assert!(everyone(EVERYONE));
        assert!(everyone(LONG_FIRST));
    }

    /// The defect this replaces: a search for the word found `EveryoneModeUpdateTime`, and the radio ran with AirDrop in Contacts Only.
    #[test]
    fn contacts_only_after_everyone_is_not_everyone() {
        assert_eq!(discoverable_mode(CONTACTS).as_deref(), Some("Contacts Only"));
        assert!(!everyone(CONTACTS));
    }

    #[test]
    fn a_bad_plist_is_not_everyone() {
        assert!(!everyone(b"bplist00"));
        assert!(!everyone(b"bplist00SOff"));
        assert!(!everyone(&[0u8; 64]));
        let mut cut = EVERYONE.to_vec();
        cut.truncate(EVERYONE.len() - 1);
        assert!(!everyone(&cut));
        let mut wild = EVERYONE.to_vec();
        let n = wild.len();
        wild[n - 8..].copy_from_slice(&u64::MAX.to_be_bytes()); // an offset table past the end
        assert!(!everyone(&wild));
    }

    #[test]
    fn en0_comes_first() {
        assert!(pick(1, 0, 5220, Proof::SharedOk, Allow::Shared, 99).is_err());
        assert_eq!(pick(0, 0, 5745, Proof::AloneOk, Allow::Nothing, 99), Ok((5745, false)));
        assert!(pick(2, 5180, 5220, Proof::SharedOk, Allow::Shared, 99).is_err()); // channel 36
        assert!(pick(2, 5220, 5220, Proof::None, Allow::Shared, 99).is_err()); // never alone yet
        assert_eq!(pick(2, 5220, 5745, Proof::AloneOk, Allow::Shared, 99), Ok((5220, true)));
        assert_eq!(pick(2, 2437, 5745, Proof::SharedOk, Allow::Nothing, 99), Ok((2437, true)));
    }

    /// CLAUDE.md: a failure never takes Wi-Fi. What can stop the modem does not run by itself: by default, nothing is sent.
    #[test]
    fn by_default_nothing_untested_reaches_the_firmware() {
        assert_eq!(pick(0, 0, 5220, Proof::None, Allow::Nothing, 99), Err(GATE_ALONE));
        assert_eq!(pick(2, 5220, 5220, Proof::AloneOk, Allow::Nothing, 99), Err(GATE_SHARED));
        assert_eq!(pick(2, 5220, 5220, Proof::AloneOk, Allow::Alone, 99), Err(GATE_SHARED));
        assert_eq!(pick(0, 0, 5220, Proof::None, Allow::Alone, 99), Ok((5220, false)));
        assert_eq!(pick(0, 0, 5220, Proof::None, Allow::Shared, 99), Ok((5220, false)));
    }

    /// Also with the owner's file: a failure stays until the state file goes.
    #[test]
    fn a_failure_is_never_tried_again_by_itself() {
        for p in [Proof::Failed, Proof::TryingAlone, Proof::TryingShared] {
            assert!(pick(0, 0, 5220, p, Allow::Shared, 99).is_err());
            assert!(pick(2, 5220, 5220, p, Allow::Shared, 99).is_err());
        }
    }

    #[test]
    fn en0_idle_at_boot_is_not_idle_yet() {
        assert_eq!(pick(0, 0, 5220, Proof::AloneOk, Allow::Nothing, EN0_SETTLE_S - 1), Err("en0 may join soon: waiting"));
        assert_eq!(pick(0, 0, 5220, Proof::AloneOk, Allow::Nothing, EN0_SETTLE_S), Ok((5220, false)));
    }

    #[test]
    fn allow_file() {
        assert_eq!(Allow::parse("alone\n"), Allow::Alone);
        assert_eq!(Allow::parse("shared"), Allow::Shared);
        assert_eq!(Allow::parse(""), Allow::Nothing);
        assert_eq!(Allow::parse("yes"), Allow::Nothing);
    }

    #[test]
    fn who_stopped_the_modem() {
        assert!(modem_stop_is_ours(4, 0)); // up
        assert!(modem_stop_is_ours(6, 0)); // stopping
        assert!(modem_stop_is_ours(0, BLAME_MS - 1)); // just after the end
        assert!(!modem_stop_is_ours(0, BLAME_MS));
        assert!(!modem_stop_is_ours(0, u32::MAX)); // it never ran
    }

    #[test]
    fn awdl0_type_follows_the_kernel() {
        assert!(typed_awdl0("25.5.0") && typed_awdl0("26.0.0"));
        assert!(!typed_awdl0("22.6.0") && !typed_awdl0("") && !typed_awdl0("x"));
    }

    #[test]
    fn wanted_by_mode_or_advert() {
        assert!(wanted(true, u32::MAX));
        assert!(wanted(false, 5));
        assert!(!wanted(false, BLE_LINGER_S));
    }
}
