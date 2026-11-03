//! `op10tool input`: touch and keys through the Mi A3 kernel's real HID path, from the USB command server (kernel patch 2983; docs/laurel_sprout/ios26-autotest.md).
//! The same gestures as userland/laurel/autotest/laurel_autotest.m, which takes the way with no kernel patch.
//! Words, one per datagram: "touch F D X Y", "key K D", "synth". The kernel replies "ok", "synth on|off" or "error: ...".

use crate::ctl;
use anyhow::{bail, Result};
use clap::Subcommand;
use std::net::UdpSocket;
use std::thread::sleep;
use std::time::{Duration, Instant};

const PANEL_W: i32 = 720;
const PANEL_H: i32 = 1560;
const STEP_MS: i32 = 8;
/// Not finger 0: a real finger on the panel keeps its own state.
const FINGER: i32 = 9;
const REPLY_MS: u64 = 300;

#[derive(Subcommand, Debug, Clone)]
pub enum Action {
    /// Exit 0 if this kernel has the feature on
    Check,
    Tap {
        x: i32,
        y: i32,
        #[arg(default_value_t = 50)]
        ms: i32,
    },
    Swipe {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        #[arg(default_value_t = 300)]
        ms: i32,
    },
    /// From a screen edge: bottom, top, left, right
    Edge {
        side: String,
        len: Option<i32>,
        #[arg(default_value_t = 300)]
        ms: i32,
        at: Option<i32>,
    },
    /// power, volup, voldown, home
    Key {
        name: String,
        #[arg(default_value_t = 80)]
        ms: i32,
    },
}

/// (delay before this word in ms, the word). Same steps as touch_path of laurel_autotest.m.
pub fn touch_words(x0: i32, y0: i32, x1: i32, y1: i32, ms: i32) -> Vec<(i32, String)> {
    let steps = if ms <= STEP_MS { 1 } else { ms / STEP_MS };
    let mut out = vec![(0, format!("touch {FINGER} 1 {x0} {y0}"))];
    for i in 1..=steps {
        out.push((STEP_MS, format!("touch {FINGER} 1 {} {}", x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)));
    }
    out.push((STEP_MS, format!("touch {FINGER} 0 {x1} {y1}")));
    out
}

pub fn edge_words(side: &str, len: Option<i32>, ms: i32, at: Option<i32>) -> Result<Vec<(i32, String)>> {
    let vertical = side == "bottom" || side == "top";
    let len = len.unwrap_or(if vertical { 800 } else { 400 });
    let at = at.unwrap_or(if vertical { PANEL_W / 2 } else { PANEL_H / 2 });
    Ok(match side {
        "bottom" => touch_words(at, PANEL_H - 2, at, PANEL_H - 2 - len, ms),
        "top" => touch_words(at, 2, at, 2 + len, ms),
        "left" => touch_words(2, at, 2 + len, at, ms),
        "right" => touch_words(PANEL_W - 3, at, PANEL_W - 3 - len, at, ms),
        _ => bail!("edge {side}: bottom, top, left or right"),
    })
}

pub fn key_words(name: &str, ms: i32) -> Result<Vec<(i32, String)>> {
    let k = match name {
        "power" => 0,
        "volup" => 1,
        "voldown" => 2,
        "home" => 3,
        _ => bail!("key {name}: power, volup, voldown or home"),
    };
    Ok(vec![(0, format!("key {k} 1")), (ms, format!("key {k} 0"))])
}

fn ask(sock: &UdpSocket, word: &str) -> Result<String> {
    sock.send(word.as_bytes())?;
    sock.set_read_timeout(Some(Duration::from_millis(REPLY_MS)))?;
    let mut buf = [0u8; 256];
    match sock.recv(&mut buf) {
        Ok(n) => Ok(String::from_utf8_lossy(&buf[..n]).trim().to_string()),
        Err(e) => bail!("no reply to {word:?}: {e}"),
    }
}

/// Keeps the 8 ms grid against the send time, so a late reply does not stretch a swipe.
fn send_words(sock: &UdpSocket, words: &[(i32, String)]) -> Result<()> {
    let mut next = Instant::now();
    for (delay, word) in words {
        next += Duration::from_millis(*delay as u64);
        let now = Instant::now();
        if next > now {
            sleep(next - now);
        }
        let r = ask(sock, word)?;
        if r != "ok" {
            bail!("{word:?}: {r}");
        }
    }
    Ok(())
}

pub fn run(action: Action, host: &str) -> Result<()> {
    let (sock, _) = ctl::socket(host)?;
    let words = match action {
        Action::Check => {
            let r = ask(&sock, "synth")?;
            println!("{r}");
            if r != "synth on" {
                bail!("the kernel has no input path on: {r} (kernel without patch 2983 replies \"error: unknown command\")");
            }
            return Ok(());
        }
        Action::Tap { x, y, ms } => touch_words(x, y, x, y, ms),
        Action::Swipe { x0, y0, x1, y1, ms } => touch_words(x0, y0, x1, y1, ms),
        Action::Edge { side, len, ms, at } => edge_words(&side, len, ms, at)?,
        Action::Key { name, ms } => key_words(&name, ms)?,
    };
    send_words(&sock, &words)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_swipe_starts_moves_and_ends_where_asked() {
        let w = touch_words(100, 200, 300, 400, 32);
        assert_eq!(w.first().unwrap(), &(0, "touch 9 1 100 200".to_string()));
        assert_eq!(w[w.len() - 2].1, "touch 9 1 300 400");
        assert_eq!(w.last().unwrap(), &(8, "touch 9 0 300 400".to_string()));
        assert_eq!(w.len(), 6);
        assert!(w[1..].iter().all(|(d, _)| *d == 8));
    }

    #[test]
    fn a_tap_stays_in_place() {
        assert!(touch_words(10, 20, 10, 20, 50).iter().all(|(_, s)| s.ends_with(" 10 20")));
    }

    #[test]
    fn edges_start_inside_the_kernels_edge_zone() {
        assert!(edge_words("bottom", None, 8, None).unwrap()[0].1.ends_with(" 360 1558"));
        assert!(edge_words("top", Some(700), 8, Some(650)).unwrap()[0].1.ends_with(" 650 2"));
        assert!(edge_words("right", None, 8, None).unwrap()[0].1.ends_with(" 717 780"));
        assert!(edge_words("nope", None, 8, None).is_err());
    }

    #[test]
    fn keys_go_down_then_up_with_the_kernels_numbers() {
        assert_eq!(key_words("home", 80).unwrap(), vec![(0, "key 3 1".to_string()), (80, "key 3 0".to_string())]);
        assert_eq!(key_words("power", 5).unwrap()[0].1, "key 0 1");
        assert!(key_words("x", 5).is_err());
    }
}
