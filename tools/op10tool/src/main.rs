//! op10tool: the binary-heavy tools of iOSPlus10 in one cross-platform CLI (macOS, Linux).
//! Simple glue stays in shell/Python under scripts/.

mod a64;
mod a64test;
mod abi;
mod lower;
mod bootlog;
mod camframe;
mod census;
mod ctl;
mod dsc;
mod fat;
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
    /// Print the HFS+ volume size in bytes of a raw root image (block size x total blocks from the volume header);
    /// with --trim, truncate the file to that size (a simg2img output is partition-sized)
    HfsSize { input: PathBuf, #[arg(long)] trim: bool },
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
    /// FAT16/FAT32 index of a modem firmware image (NON-HLOS.bin, modem_a/modem_b dump), made like the
    /// kernel's (laurel patch 2400): summary line as the phone logs it, then every file; with PATHs only
    /// those (size, first cluster, runs, CRC-32), exit 1 if one is missing
    Fatls {
        image: PathBuf,
        paths: Vec<String>,
        /// size of the partition the image stands for (the kernel checks the volume against the GPT size)
        #[arg(long, value_parser = parse_u64, default_value_t = fat::MI_A3_MODEM_BYTES)]
        part_bytes: u64,
    },
    /// Extract the payload of an IM4P (raw or LZFSE)
    Im4p { input: PathBuf, output: PathBuf },
    /// Census of a dyld shared cache and Mach-O tree on an ARMv8.0 CPU (needs llvm-mc): classes, LSE, PAC, slide info, layout
    A64Census {
        /// Main dyld_shared_cache_arm64e file (subcaches next to it)
        #[arg(long)]
        cache: Option<PathBuf>,
        /// Tree of Mach-O files; all arm64e slices are counted (repeatable)
        #[arg(long)]
        root: Vec<PathBuf>,
        /// Output folder
        #[arg(long)]
        out: PathBuf,
        /// Use at most N root files, evenly spaced (0 = all)
        #[arg(long, default_value_t = 0)]
        sample: usize,
        /// Count every arm64 slice, not only arm64e (for a lowered tree)
        #[arg(long)]
        all_slices: bool,
    },
    /// Run each LSE form natively (qemu -cpu max) and through its trampoline (qemu -cpu cortex-a53); compare every register, NZCV, red zone and memory
    A64Selftest {
        /// Extra words, one hex per line (lse-words.txt of a64-lower)
        #[arg(long)]
        words: Option<PathBuf>,
        /// Work folder
        #[arg(long)]
        out: PathBuf,
    },
    /// Write a lowered copy of a dyld shared cache for an ARMv8.0 CPU (never in place): PAC, RCpc, LSE trampolines, DIT, auth rebases, new signatures
    A64Lower {
        /// Main dyld_shared_cache_arm64e file (subcaches next to it)
        #[arg(long)]
        cache: Option<PathBuf>,
        /// One Mach-O file or a tree of them (repeatable)
        #[arg(long)]
        macho: Vec<PathBuf>,
        /// New output folder
        #[arg(long)]
        out: PathBuf,
        /// Comma list: all, pac, rcpc, lse, sysreg, slide
        #[arg(long, default_value = "all")]
        rules: String,
        /// Code-signature page shift of the output (12 for a 4 KiB kernel; 0 keeps the file's own and rehashes in place)
        #[arg(long, default_value_t = 0)]
        page_shift: u32,
        /// Image never loaded on this device (substring, repeatable): its __text becomes trampoline space and it is not lowered
        #[arg(long)]
        dead_image: Vec<String>,
        /// Plan only: report the numbers and write no output
        #[arg(long)]
        plan: bool,
    },
    /// Check a lowered copy against the original: only allowed word changes, trampolines valid on cortex-a73, signatures, slide chains
    A64Verify {
        /// Main cache file of the original
        #[arg(long)]
        orig: PathBuf,
        /// Output folder of a64-lower
        #[arg(long)]
        lowered: PathBuf,
        /// Same list as a64-lower --dead-image
        #[arg(long)]
        dead_image: Vec<String>,
        /// Tree of the original Mach-O files: also check `lowered/macho`
        #[arg(long)]
        macho_orig: Option<PathBuf>,
    },
    /// Trace IOConnectCall* and sandbox selectors of named images in a dyld shared cache; dump symbols and strings
    A64Abi {
        #[arg(long)]
        cache: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// Disassemble a function of a cache image, or list callers of a symbol (--xref)
    A64Dis {
        #[arg(long)]
        cache: PathBuf,
        #[arg(long)]
        image: String,
        #[arg(long)]
        symbol: String,
        #[arg(long)]
        xref: bool,
        #[arg(long, default_value_t = 200)]
        count: usize,
    },
    /// Command to the negroni or Mi A3 kernel over USB Ethernet (UDP 5141): ping, reboot, bootloader, recovery, poweroff, panic, settime, time, log, bootlog
    Ctl {
        #[arg(value_enum)]
        command: ctl::Command,
        /// the phone's address
        #[arg(long, default_value = "192.168.7.2")]
        host: String,
    },
    /// Mi A3 rear camera frame over USB (kernel patch 2771): new capture, read, OUT/camframe-genN.raw10 + .png
    /// (demosaic, white balance, gamma). --raw FILE: convert a saved RAW10 frame only.
    Camframe {
        /// the phone's address
        #[arg(long, default_value = "192.168.7.2")]
        host: String,
        /// output directory
        #[arg(long, default_value = "logs/camera")]
        out: PathBuf,
        /// take the frame the phone keeps (no new capture)
        #[arg(long)]
        no_capture: bool,
        /// convert this RAW10 file (MIPI packed) instead of reading the phone
        #[arg(long)]
        raw: Option<PathBuf>,
        #[arg(long, default_value_t = 1280)]
        width: u32,
        #[arg(long, default_value_t = 720)]
        height: u32,
        /// Bayer order for --raw: RGGB, BGGR, GRBG, GBRG or TPG (grey)
        #[arg(long, default_value = "RGGB")]
        bayer: String,
    },
    /// Boot log of the last boots (kernel patch 0367; Mi A3 2900): writes OUT/bootlog-<boot>.txt per boot and prints one
    /// summary line per boot (end: panic / reset without panic / clean / still running) and its last 5 lines.
    /// Source: the USB command server (UDP 5141) or --file (dump of /dev/negronibootlog, /dev/laurelbootlog or of the area)
    Bootlog {
        /// only the newest COUNT boots (default: every valid slot, at most 8)
        count: Option<usize>,
        /// the phone's address
        #[arg(long, default_value = "192.168.7.2")]
        host: String,
        /// read an area dump instead of the phone (scripts/debug/bootlog-ssh.sh makes one over SSH)
        #[arg(long)]
        file: Option<PathBuf>,
        /// directory for bootlog-<boot>.txt
        #[arg(long, default_value = "logs")]
        out: PathBuf,
        /// where to look for kernel builds by UUID (out/kernel/*/kernel.*)
        #[arg(long, default_value = "out/kernel")]
        kernels: PathBuf,
        /// only write the area superblock (one 4096-byte block) to this file (scripts/ios16/root-simg.sh)
        #[arg(long)]
        mkarea: Option<PathBuf>,
    },
}

fn parse_int(s: &str) -> Result<usize, String> {
    let r = if let Some(h) = s.strip_prefix("0x") { usize::from_str_radix(h, 16) } else { s.parse() };
    r.map_err(|e| e.to_string())
}

fn parse_u64(s: &str) -> Result<u64, String> {
    let r = if let Some(h) = s.strip_prefix("0x") { u64::from_str_radix(h, 16) } else { s.parse() };
    r.map_err(|e| e.to_string())
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Img2simg { input, output } => img2simg::img2simg(&input, &output),
        Cmd::Simg2img { input, output } => img2simg::simg2img(&input, &output),
        Cmd::HfsSize { input, trim } => img2simg::hfs_size(&input, trim),
        Cmd::IpswGet { url, outdir, names, jobs, chunk_mib } => ipsw::run(&url, &outdir, &names, jobs, chunk_mib << 20),
        Cmd::UefiUnpack { image, outdir } => uefi::run(&image, &outdir),
        Cmd::UefiPortpatch { orig, patched, target, out, skip, byte } => {
            let ok = portpatch::run(&orig, &patched, &target, &out, &skip, &byte)?;
            std::process::exit(if ok { 0 } else { 1 })
        }
        Cmd::Fatls { image, paths, part_bytes } => fat::run(&image, &paths, part_bytes),
        Cmd::Im4p { input, output } => im4p::run(&input, &output),
        Cmd::A64Census { cache, root, out, sample, all_slices } => census::run(cache.as_deref(), &root, &out, sample, all_slices),
        Cmd::A64Selftest { words, out } => a64test::run(words.as_deref(), &out),
        Cmd::A64Lower { cache, macho, out, rules, page_shift, dead_image, plan } => {
            lower::run(cache.as_deref(), &macho, &out, &rules, page_shift, &dead_image, plan)
        }
        Cmd::A64Verify { orig, lowered, dead_image, macho_orig } => lower::verify(&orig, &lowered, &dead_image, macho_orig.as_deref()),
        Cmd::A64Abi { cache, out } => abi::run(&cache, &out),
        Cmd::A64Dis { cache, image, symbol, xref, count } => abi::dis(&cache, &image, &symbol, xref, count, std::path::Path::new("out/ios26/tmp-dis")),
        Cmd::Ctl { command, host } => ctl::run(command, &host),
        Cmd::Camframe { host, out, no_capture, raw, width, height, bayer } => {
            camframe::run(camframe::Args { host, out, no_capture, raw, width, height, bayer })
        }
        Cmd::Bootlog { count, host, file, out, kernels, mkarea } => {
            bootlog::run(bootlog::Args { count, host, file, out, kernels, mkarea })
        }
    }
}
