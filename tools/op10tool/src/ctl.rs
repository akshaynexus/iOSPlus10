//! Commands to the negroni kernel's USB command server (patches/xnu/0210-negroni-usb-command-server.patch,
//! bsd/dev/negroni_usb.c): one ASCII word per UDP datagram to 192.168.7.2:5141, sent from the host side of the
//! USB Ethernet link (192.168.7.1, set up by scripts/debug/usblog.sh). The kernel accepts only 192.168.7.1 as
//! the source and replies to the sending port: "pong" for ping, "ok <command>" before a reset, power off or
//! panic (which follows 500 ms later), "error: ..." otherwise.
//! Calendar (patch 0212, bsd/dev/negroni_rtc.c from 0203): `settime` sends "settime <unix s>.<us>" with this
//! host's clock (reply "ok settime ..."), `time` asks "time" (reply "time <s> rtc <counter> offset <n> source ...").
//! Panic mode (patch 0360, patches/xnu/README-panic.md): after a panic the kernel still answers ping
//! ("pong (panic)"), log, reboot, bootloader, recovery and poweroff (replies end in "(panic)").
//! `log` makes the kernel send the last 64 KiB of its console to the live log (UDP 5140) again.

use anyhow::{bail, Context, Result};
use clap::ValueEnum;
use std::io::ErrorKind;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const PORT: u16 = 5141;
const HOST_IP: &str = "192.168.7.1";

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum Command {
    /// Reply "pong" (waits up to 2 s)
    Ping,
    /// PSCI SYSTEM_RESET (reboot reason normal)
    Reboot,
    /// Reboot reason 2 (ABL fastboot), then reset
    Bootloader,
    /// Reboot reason 1 (recovery), then reset
    Recovery,
    /// PSCI SYSTEM_OFF (boot-arg negronipoweroff selects the PMIC fallback)
    Poweroff,
    /// panic("requested over USB"), so the panic log path runs
    Panic,
    /// Set the phone's calendar to this host's clock (UTC); the kernel keeps the PMIC RTC offset
    Settime,
    /// Show the phone's calendar, RTC counter and offset (no change)
    Time,
    /// Send the last 64 KiB of the console to the live log again (also after a panic, patch 0360)
    Log,
    /// The USB gadget's counters: frames, bytes, TX drops, RX frames per poll, TX batch size (patch 0361)
    Usbstats,
}

impl Command {
    fn word(self) -> String {
        match self {
            Command::Ping => "ping".into(),
            Command::Usbstats => "usbstats".into(),
            Command::Reboot => "reboot".into(),
            Command::Bootloader => "bootloader".into(),
            Command::Recovery => "recovery".into(),
            Command::Poweroff => "poweroff".into(),
            Command::Panic => "panic".into(),
            Command::Settime => {
                let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
                format!("settime {}.{:06}", now.as_secs(), now.subsec_micros())
            }
            Command::Time => "time".into(),
            Command::Log => "log".into(),
        }
    }
}

/// Waits until `deadline` for a datagram from the phone (the socket is connected to it); None on timeout.
fn recv(sock: &UdpSocket, phone: SocketAddr, deadline: Instant) -> Result<Option<String>> {
    let mut buf = [0u8; 512];
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        return Ok(None);
    }
    sock.set_read_timeout(Some(left))?;
    match sock.recv(&mut buf) {
        Ok(n) => Ok(Some(String::from_utf8_lossy(&buf[..n]).trim().to_string())),
        Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => Ok(None),
        // ICMP port unreachable: the phone's IP stack got the datagram, so its kernel has no command server.
        Err(e) if e.kind() == ErrorKind::ConnectionRefused => {
            bail!("{phone} refused the datagram (ICMP port unreachable): kernel without the command server, or negronictl=0")
        }
        Err(e) => Err(e.into()),
    }
}

pub fn run(cmd: Command, host: &str) -> Result<()> {
    let ip: IpAddr = host.parse().with_context(|| format!("--host {host}: not an IP address"))?;
    let phone = SocketAddr::new(ip, PORT);
    // The kernel accepts only 192.168.7.1 as the source: on the USB link, send from exactly that address.
    let sock = if matches!(ip, IpAddr::V4(v4) if v4.octets()[..3] == [192, 168, 7]) {
        UdpSocket::bind((HOST_IP, 0)).with_context(|| {
            format!("{HOST_IP} is not set on this host: start the USB link first (make usblog, scripts/debug/usblog.sh)")
        })?
    } else {
        UdpSocket::bind(("0.0.0.0", 0)).context("bind a UDP socket")?
    };
    sock.connect(phone).with_context(|| format!("no route to {phone} (see scripts/debug/usblog.sh)"))?;
    let send = || {
        sock.send(cmd.word().as_bytes()).with_context(|| {
            format!("send to {phone} (is the phone's USB Ethernet up and 192.168.7.1/24 set on the host? see scripts/debug/usblog.sh)")
        })
    };
    let start = Instant::now();
    match cmd {
        Command::Ping => {
            // ping has no side effect: resend every 500 ms (the first datagram can be lost while the host resolves ARP).
            let deadline = start + Duration::from_secs(2);
            while Instant::now() < deadline {
                send()?;
                let slot = (Instant::now() + Duration::from_millis(500)).min(deadline);
                if let Some(reply) = recv(&sock, phone, slot)? {
                    // "pong", or "pong (panic)" from the panic hold loop (patch 0360)
                    if !reply.starts_with("pong") {
                        bail!("{phone}: unexpected reply {reply:?}");
                    }
                    println!("{reply} from {phone} in {:.1} ms", start.elapsed().as_secs_f64() * 1e3);
                    return Ok(());
                }
            }
            bail!("no pong from {phone} in 2 s")
        }
        Command::Settime | Command::Time | Command::Log | Command::Usbstats => {
            // No reset: resend every 500 ms like ping (each settime carries the host's time at sending).
            let deadline = start + Duration::from_secs(2);
            while Instant::now() < deadline {
                send()?;
                let slot = (Instant::now() + Duration::from_millis(500)).min(deadline);
                if let Some(reply) = recv(&sock, phone, slot)? {
                    if reply.starts_with("error") {
                        bail!("{phone}: {reply}");
                    }
                    println!("{phone}: {reply}");
                    if let Some(t) = reply.strip_prefix("time ").and_then(|r| r.split(' ').next()?.parse::<i64>().ok()) {
                        let host = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
                        println!("phone - host = {} s", t - host);
                    }
                    return Ok(());
                }
            }
            bail!("no reply from {phone} in 2 s (kernel without patch 0212 replies \"error: unknown command\")")
        }
        _ => {
            // Sent once: a reset or panic must not run twice.
            send()?;
            match recv(&sock, phone, start + Duration::from_secs(2))? {
                Some(reply) if reply.starts_with("ok") => {
                    println!("{phone}: {reply} (the phone acts in 500 ms)");
                    Ok(())
                }
                Some(reply) => bail!("{phone}: {reply}"),
                None => bail!("no reply from {phone} in 2 s (the command may still have run; check the live log)"),
            }
        }
    }
}
