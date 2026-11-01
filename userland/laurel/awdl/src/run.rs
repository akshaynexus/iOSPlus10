//! The daemon's loop: when to run, the session, the Node between the kernel and awdl0.
use std::io::{self, Write};
use std::time::{Duration, Instant};

use laurel_awdld::policy::{self, Allow, Proof};
use owly_awdl::MacAddr;

use crate::ctl::{self, Ctl};
use crate::session::run_node;

const STATE_FILE: &str = "/private/var/db/laurel-awdl.state";
const ALLOW_FILE: &str = "/private/var/db/laurel-awdl.allow";
const PREFS: &str = "/private/var/mobile/Library/Preferences/com.apple.sharingd.plist";
const MSG_START: u8 = 1;
const MSG_STOP: u8 = 2;
const MSG_IF_UP: u8 = 7;
const LW_AR_IF_TYPED: u8 = 1;
/// Longer than the longest scan (max scan time 20 s, scan_send_start): the kernel holds the vdev's start until the scan ends.
const START_WAIT_S: u64 = 30;

pub(crate) fn say(text: &str) {
    let line = format!("LAUREL AWDL: {text}\n");
    if let Ok(mut c) = std::fs::OpenOptions::new().write(true).open("/dev/console") {
        let _ = c.write_all(line.as_bytes());
    }
    let _ = io::stderr().write_all(line.as_bytes());
}

fn switched_off() -> bool {
    ctl::sysctl_string("kern.bootargs").split_whitespace().any(|w| w == "awdl=0")
}

pub(crate) fn proof() -> Proof {
    Proof::parse(&std::fs::read_to_string(STATE_FILE).unwrap_or_default())
}

fn allow() -> Allow {
    Allow::parse(&std::fs::read_to_string(ALLOW_FILE).unwrap_or_default())
}

/// The whole file or nothing, on the disk before the start: a panic in the next second must find it. `Err`: no start, because no failure could be remembered.
pub(crate) fn set_proof(p: Proof) -> io::Result<()> {
    let tmp = format!("{STATE_FILE}.new");
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(p.word().as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&tmp, STATE_FILE)?;
    std::fs::File::open("/private/var/db")?.sync_all()
}

/// The modem has stopped. Says why, once; the state file remembers it when the vdev may be the cause. The radio does not come back in this boot.
pub(crate) fn modem_stopped(st: &ctl::Status) -> End {
    if policy::modem_stop_is_ours(st.state, st.off_age_ms) {
        let saved = set_proof(Proof::Failed).is_ok();
        say(&format!("off: the modem stopped while the AWDL vdev was on or just after: Wi-Fi and cellular are gone until the next boot; AWDL stays off{}", if saved { " for good" } else { ", but the state file cannot be written" }));
    } else {
        say("off: the modem stopped, not under the AWDL vdev: no radio until the next boot");
    }
    End::Fatal
}

fn random_mac() -> MacAddr {
    let mut m = [0u8; 6];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = io::Read::read_exact(&mut f, &mut m);
    }
    m[0] = (m[0] & 0xfe) | 0x02;
    MacAddr(m)
}

fn host_name() -> String {
    let h = ctl::sysctl_string("kern.hostname");
    let h = h.split('.').next().unwrap_or("").trim().to_string();
    if h.is_empty() || h == "localhost" { "miA3".to_string() } else { h }
}

pub(crate) fn everyone() -> bool {
    std::fs::read(PREFS).map(|p| policy::everyone(&p)).unwrap_or(false)
}

pub fn main() {
    if switched_off() {
        say("off: boot-arg awdl=0");
        return;
    }
    if proof().unfinished() {
        say(&format!("off: the last start did not finish ({}): the firmware may have stopped; `rm {STATE_FILE}` tries again", proof().word()));
        return;
    }
    if let Err(e) = set_proof(proof()) {
        say(&format!("off: {STATE_FILE} cannot be written ({e}): a failure could not be remembered, so the radio does not start"));
        return;
    }
    let ctl = loop {
        match Ctl::open() {
            Ok(c) => break c,
            Err(_) => std::thread::sleep(Duration::from_secs(5)), // the kernel makes the socket when Wi-Fi is ready
        }
    };
    let mac = random_mac();
    let host = host_name();
    let typed = policy::typed_awdl0(&ctl::sysctl_string("kern.osrelease"));
    if typed {
        // iOS 26: sharingd asks for awdl0 by name when its server starts [V 23F84 0x1006d1108]; Apple's awdl0 is always there. It stays down until the cell has heard AWDL.
        if let Err(e) = ctl.send(MSG_IF_UP, &if_up_body(mac, true)) {
            say(&format!("off: awdl0: {e}"));
            return;
        }
    }
    let mut next = 0;
    let mut said_why: Option<&'static str> = None;
    let mut refused = 0;
    let mut en0_idle = Instant::now();
    loop {
        let st = match ctl.status() {
            Ok(s) => s,
            Err(e) => {
                say(&format!("off: the kernel's socket failed: {e}"));
                return;
            }
        };
        if st.fw_fatal != 0 {
            modem_stopped(&st);
            return;
        }
        if st.en0_state != 0 {
            en0_idle = Instant::now();
        }
        if !policy::wanted(everyone(), st.ble_age_s) {
            std::thread::sleep(Duration::from_secs(2));
            continue;
        }
        let chan = policy::CHANNELS[next % policy::CHANNELS.len()];
        let (freq, share) = match policy::pick(st.en0_state, st.en0_freq, chan, proof(), allow(), en0_idle.elapsed().as_secs()) {
            Ok(p) => p,
            Err(why) => {
                if said_why != Some(why) {
                    say(&format!("off: {why}"));
                    said_why = Some(why);
                }
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        said_why = None;
        match session(&ctl, mac, &host, freq, share, typed) {
            End::NoPeers => next += 1,
            End::Stop => {}
            End::Refused => {
                std::thread::sleep(Duration::from_secs(30));
            }
            End::FwRefused => {
                refused += 1;
                if refused >= 3 {
                    say("off: the firmware refused the IBSS vdev 3 times: off until the next boot");
                    return;
                }
                next += 1;
            }
            End::Fatal => return,
        }
    }
}

pub(crate) enum End {
    NoPeers,
    Stop,
    Refused,
    FwRefused,
    Fatal,
}

/// LW_AR_MSG_IF_UP. iOS 16: the MAC alone, as before.
pub(crate) fn if_up_body(mac: MacAddr, typed: bool) -> Vec<u8> {
    let mut b = mac.0.to_vec();
    if typed {
        b.push(LW_AR_IF_TYPED);
    }
    b
}

fn start_body(freq: u16, mac: MacAddr, share: bool) -> Vec<u8> {
    let mut b = freq.to_le_bytes().to_vec();
    b.extend_from_slice(&mac.0);
    b.push(share as u8);
    b
}

/// One channel, from START to the end of the vdev.
fn session(ctl: &Ctl, mac: MacAddr, host: &str, freq: u16, share: bool, typed: bool) -> End {
    let before = proof();
    let trying = if !share && before == Proof::None {
        Some(Proof::TryingAlone)
    } else if share && before == Proof::AloneOk {
        Some(Proof::TryingShared)
    } else {
        None
    };
    if let Some(t) = trying {
        if let Err(e) = set_proof(t) {
            say(&format!("off: {STATE_FILE} cannot be written ({e}): a failure could not be remembered, so the radio does not start"));
            return End::Fatal;
        }
    }
    let restore = || {
        if trying.is_some() {
            let _ = set_proof(before);
        }
    };
    if let Err(e) = ctl.send(MSG_START, &start_body(freq, mac, share)) {
        say(&format!("off: the kernel refused the start: {e}"));
        restore();
        return End::Refused;
    }
    let t0 = Instant::now();
    loop {
        let st = ctl.status().unwrap_or_default();
        if st.state == ctl::STATE_UP {
            break;
        }
        if st.fw_fatal != 0 {
            return modem_stopped(&st);
        }
        if st.why == ctl::WHY_START_TIMEOUT {
            say("off: the firmware did not answer the vdev's start: the state file keeps this off, in case it has stopped");
            return End::Fatal; // the state file keeps `trying`
        }
        if st.state == ctl::STATE_OFF && st.why != 0 {
            restore(); // the firmware answered, or en0 was first: no danger shown. The kernel says why.
            return if st.why == ctl::WHY_START_STATUS { End::FwRefused } else { End::Refused };
        }
        if t0.elapsed() > Duration::from_secs(START_WAIT_S) {
            let _ = ctl.send(MSG_STOP, &[]);
            if st.state < ctl::STATE_STARTING {
                // no VDEV_START went out: a long scan is no sign of a sick firmware
                say(&format!("off: the vdev did not get a turn in {START_WAIT_S} s: scans come first"));
                restore();
                return End::Refused;
            }
            say(&format!("off: the vdev did not start in {START_WAIT_S} s"));
            return End::Fatal; // the state file keeps `trying`: the firmware is not well
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    run_node(ctl, mac, host, freq, share, before, typed)
}
