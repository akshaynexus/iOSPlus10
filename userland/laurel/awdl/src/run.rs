//! The daemon's loop: when to run, the session, the Node between the kernel and awdl0.
use std::io::{self, Write};
use std::time::{Duration, Instant};

use laurel_awdld::policy::{self, Proof};
use owly_awdl::MacAddr;

use crate::ctl::{self, Ctl};
use crate::session::run_node;

const STATE_FILE: &str = "/private/var/db/laurel-awdl.state";
const PREFS: &str = "/private/var/mobile/Library/Preferences/com.apple.sharingd.plist";
const MSG_START: u8 = 1;
const MSG_STOP: u8 = 2;

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

pub(crate) fn set_proof(p: Proof) {
    if let Ok(mut f) = std::fs::File::create(STATE_FILE) {
        let _ = f.write_all(p.word().as_bytes());
        let _ = f.sync_all();
    }
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
    let ctl = loop {
        match Ctl::open() {
            Ok(c) => break c,
            Err(_) => std::thread::sleep(Duration::from_secs(5)), // the kernel makes the socket when Wi-Fi is ready
        }
    };
    let mac = random_mac();
    let host = host_name();
    let mut next = 0;
    let mut said_why: Option<&'static str> = None;
    let mut refused = 0;
    loop {
        let st = match ctl.status() {
            Ok(s) => s,
            Err(e) => {
                say(&format!("off: the kernel's socket failed: {e}"));
                return;
            }
        };
        if !policy::wanted(everyone(), st.ble_age_s) {
            std::thread::sleep(Duration::from_secs(2));
            continue;
        }
        let chan = policy::CHANNELS[next % policy::CHANNELS.len()];
        let (freq, share) = match policy::pick(st.en0_state, st.en0_freq, chan, proof()) {
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
        match session(&ctl, mac, &host, freq, share) {
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

fn start_body(freq: u16, mac: MacAddr, share: bool) -> Vec<u8> {
    let mut b = freq.to_le_bytes().to_vec();
    b.extend_from_slice(&mac.0);
    b.push(share as u8);
    b
}

/// One channel, from START to the end of the vdev.
fn session(ctl: &Ctl, mac: MacAddr, host: &str, freq: u16, share: bool) -> End {
    let before = proof();
    if !share && before == Proof::None {
        set_proof(Proof::TryingAlone);
    } else if share && before == Proof::AloneOk {
        set_proof(Proof::TryingShared);
    }
    if let Err(e) = ctl.send(MSG_START, &start_body(freq, mac, share)) {
        say(&format!("off: the kernel refused the start: {e}"));
        set_proof(before);
        return End::Refused;
    }
    let t0 = Instant::now();
    loop {
        let st = ctl.status().unwrap_or_default();
        if st.state == ctl::STATE_UP {
            break;
        }
        if st.fw_fatal != 0 || st.why == ctl::WHY_START_TIMEOUT {
            say("off: the firmware did not answer or the modem stopped during the start: Wi-Fi may be gone until the next boot; the state file keeps this off");
            return End::Fatal; // the state file keeps `trying`
        }
        if st.state == ctl::STATE_OFF && st.why != 0 {
            set_proof(before); // the firmware answered, or en0 was first: no danger shown. The kernel says why.
            return if st.why == ctl::WHY_START_STATUS { End::FwRefused } else { End::Refused };
        }
        if t0.elapsed() > Duration::from_secs(6) {
            say("off: the vdev did not start in 6 s");
            let _ = ctl.send(MSG_STOP, &[]);
            return End::Fatal; // the state file keeps `trying`: the firmware is not well
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    run_node(ctl, mac, host, freq, share, before)
}
