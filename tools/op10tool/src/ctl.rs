//! Commands to the negroni kernel's USB command server (patches/xnu/0210-negroni-usb-command-server.patch,
//! bsd/dev/negroni_usb.c): one ASCII word per UDP datagram to 192.168.7.2:5141, sent from the host side of the
//! USB Ethernet link (192.168.7.1, set up by scripts/debug/usblog.sh). The kernel accepts only 192.168.7.1 as
//! the source and replies to the sending port: "pong" for ping, "ok <command>" before a reset or panic
//! (which follows 500 ms later), "error: ..." otherwise.

use anyhow::{bail, Context, Result};
use clap::ValueEnum;
use std::io::ErrorKind;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

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
    /// panic("requested over USB"), so the panic log path runs
    Panic,
}

impl Command {
    fn word(self) -> &'static str {
        match self {
            Command::Ping => "ping",
            Command::Reboot => "reboot",
            Command::Bootloader => "bootloader",
            Command::Recovery => "recovery",
            Command::Panic => "panic",
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
                    if reply != "pong" {
                        bail!("{phone}: unexpected reply {reply:?}");
                    }
                    println!("pong from {phone} in {:.1} ms", start.elapsed().as_secs_f64() * 1e3);
                    return Ok(());
                }
            }
            bail!("no pong from {phone} in 2 s")
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
