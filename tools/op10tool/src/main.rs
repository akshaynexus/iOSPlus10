//! op10tool: the binary-heavy tools of iOSPlus10 in one cross-platform CLI (macOS, Linux).
//! Simple glue stays in shell/Python under scripts/.

mod ctl;
mod im4p;
mod img2simg;
mod ipsw;
mod portpatch;
mod uefi;

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "op10tool", version, about = "iOSPlus10 binary tools")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Raw image -> Android sparse image (holes -> DONT_CARE, uniform blocks -> FILL, 4 KiB blocks)
    Img2simg { input: PathBuf, output: PathBuf },
    /// Android sparse image -> raw image (for checks)
    Simg2img { input: PathBuf, output: PathBuf },
    /// Download members of a remote ZIP (IPSW) with parallel range requests; CRC-32 checked
    IpswGet {
        url: String,
        outdir: PathBuf,
        names: Vec<String>,
        #[arg(short = 'j', long, default_value_t = 32)]
        jobs: usize,
        #[arg(long, default_value_t = 32)]
        chunk_mib: u64,
    },
    /// Unpack a Qualcomm uefi.img: OUTDIR/<FILE_GUID>/{pe32.efi,depex.bin,raw.bin,name.txt,...}
    UefiUnpack { image: PathBuf, outdir: PathBuf },
    /// Port byte patches between two builds of a UEFI driver (masked aarch64 context match)
    UefiPortpatch {
        orig: PathBuf,
        patched: PathBuf,
        target: PathBuf,
        out: PathBuf,
        /// r0q patch-run offset to skip (hex or decimal)
        #[arg(long, value_parser = parse_int)]
        skip: Vec<usize>,
        /// checked data patch OFF=OLD:NEW (hex)
        #[arg(long)]
        byte: Vec<String>,
    },
    /// Extract the payload of an IM4P (raw or LZFSE)
    Im4p { input: PathBuf, output: PathBuf },
    /// Command to the negroni kernel over USB Ethernet (UDP 5141): ping, reboot, bootloader, recovery, poweroff, panic, settime, time
    Ctl {
        #[arg(value_enum)]
        command: ctl::Command,
        /// the phone's address
        #[arg(long, default_value = "192.168.7.2")]
        host: String,
    },
}

fn parse_int(s: &str) -> Result<usize, String> {
    let r = if let Some(h) = s.strip_prefix("0x") { usize::from_str_radix(h, 16) } else { s.parse() };
    r.map_err(|e| e.to_string())
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Img2simg { input, output } => img2simg::img2simg(&input, &output),
        Cmd::Simg2img { input, output } => img2simg::simg2img(&input, &output),
        Cmd::IpswGet { url, outdir, names, jobs, chunk_mib } => ipsw::run(&url, &outdir, &names, jobs, chunk_mib << 20),
        Cmd::UefiUnpack { image, outdir } => uefi::run(&image, &outdir),
        Cmd::UefiPortpatch { orig, patched, target, out, skip, byte } => {
            let ok = portpatch::run(&orig, &patched, &target, &out, &skip, &byte)?;
            std::process::exit(if ok { 0 } else { 1 })
        }
        Cmd::Im4p { input, output } => im4p::run(&input, &output),
        Cmd::Ctl { command, host } => ctl::run(command, &host),
    }
}
