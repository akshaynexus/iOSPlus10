//! laurel-awdld: AWDL for AirDrop on the Mi A3. docs/laurel_sprout/airdrop-awdl.md.
//! The kernel owns the radio (patch 2932: IBSS vdev on AWDL's BSSID); owly-awdl (MIT) runs the protocol here; sharingd and mDNSResponder talk to awdl0 as to any interface.
//! One line for each change: `LAUREL AWDL: on|off: ...`, on the console and in syslog. Job com.laurel.awdl, root, no KeepAlive: when this stops, the kernel ends the vdev and Wi-Fi goes on.
#[cfg(target_os = "ios")]
mod ctl;
#[cfg(target_os = "ios")]
mod run;
#[cfg(target_os = "ios")]
mod session;

#[cfg(target_os = "ios")]
fn main() {
    run::main();
}

#[cfg(not(target_os = "ios"))]
fn main() {
    eprintln!("laurel-awdld: iOS only; the host runs `cargo test`");
    std::process::exit(2);
}
