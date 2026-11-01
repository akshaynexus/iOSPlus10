//! When the radio runs, and what the last run says about this firmware. No hardware here.
//!
//! The kernel's first IBSS vdev on this firmware has never run [U]. A firmware assert takes Wi-Fi down until the next boot, so the state file
//! holds what was tried: `trying-alone` is written before the first start; a boot that finds a `trying-*` line stops the feature.
//! A cell beside a joined en0 waits until the cell has run alone once. To try again: `rm /private/var/db/laurel-awdl.state`.

/// The file's states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Proof {
    None,
    TryingAlone,
    AloneOk,
    TryingShared,
    SharedOk,
}

impl Proof {
    pub fn parse(text: &str) -> Proof {
        match text.trim() {
            "trying-alone" => Proof::TryingAlone,
            "alone-ok" => Proof::AloneOk,
            "trying-shared" => Proof::TryingShared,
            "shared-ok" => Proof::SharedOk,
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
        }
    }

    /// At boot: the last start did not get as far as its proof.
    pub fn unfinished(self) -> bool {
        matches!(self, Proof::TryingAlone | Proof::TryingShared)
    }
}

/// How long AirDrop's Bluetooth advertisement keeps the radio on, in s.
pub const BLE_LINGER_S: u32 = 120;
/// The time a start must live for its proof, in s.
pub const PROOF_S: u64 = 10;
/// The time on one channel with no AWDL frame, in s, before the next channel. A Fixed radio only.
pub const NO_PEER_ROTATE_S: u64 = 20;

/// Does sharingd's preference file say Everyone? A binary plist holds short strings as plain ASCII. `Contacts Only` and `Off` have no such word.
pub fn everyone(plist: &[u8]) -> bool {
    const KEY: &[u8] = b"DiscoverableMode";
    const VALUE: &[u8] = b"Everyone";
    contains(plist, KEY) && contains(plist, VALUE)
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

pub fn wanted(everyone: bool, ble_age_s: u32) -> bool {
    everyone || ble_age_s < BLE_LINGER_S
}

/// AWDL's social channels, in the order that Owly tries them: an iPhone gives channel 6 a slot or two in sixteen, 44 or 149 several.
pub const CHANNELS: [u16; 3] = [5220, 5745, 2437];

/// What to do with en0 as it is. `Some(freq, share)`: start there. `None` with the text: wait, for that reason.
pub fn pick(en0_state: u32, en0_freq: u32, next_alone: u16, proof: Proof) -> Result<(u16, bool), &'static str> {
    match en0_state {
        1 => Err("en0 is joining"),
        2 => {
            if !CHANNELS.iter().any(|&c| u32::from(c) == en0_freq) {
                Err("en0 is joined on a channel that AWDL does not use (AWDL needs 6, 44 or 149), and only one channel is possible")
            } else if !matches!(proof, Proof::AloneOk | Proof::SharedOk) {
                Err("the cell must run once with en0 not joined before it runs beside en0")
            } else {
                Ok((en0_freq as u16, true))
            }
        }
        _ => Ok((next_alone, false)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proof_words_round_trip() {
        for p in [Proof::TryingAlone, Proof::AloneOk, Proof::TryingShared, Proof::SharedOk] {
            assert_eq!(Proof::parse(p.word()), p);
        }
        assert_eq!(Proof::parse("junk\n"), Proof::None);
        assert!(Proof::TryingAlone.unfinished() && Proof::TryingShared.unfinished());
        assert!(!Proof::AloneOk.unfinished() && !Proof::None.unfinished());
    }

    #[test]
    fn everyone_in_a_plist() {
        assert!(everyone(b"bplist00\xd1\x01\x02_\x10\x10DiscoverableModeXEveryone\x08"));
        assert!(!everyone(b"bplist00_\x10\x10DiscoverableMode]Contacts Only"));
        assert!(!everyone(b"bplist00SOff"));
    }

    #[test]
    fn en0_comes_first() {
        assert!(pick(1, 0, 5220, Proof::SharedOk).is_err());
        assert_eq!(pick(0, 0, 5745, Proof::None), Ok((5745, false)));
        assert!(pick(2, 5180, 5220, Proof::SharedOk).is_err()); // channel 36
        assert!(pick(2, 5220, 5220, Proof::None).is_err()); // never alone yet
        assert_eq!(pick(2, 5220, 5745, Proof::AloneOk), Ok((5220, true)));
        assert_eq!(pick(2, 2437, 5745, Proof::SharedOk), Ok((2437, true)));
    }

    #[test]
    fn wanted_by_mode_or_advert() {
        assert!(wanted(true, u32::MAX));
        assert!(wanted(false, 5));
        assert!(!wanted(false, BLE_LINGER_S));
    }
}
