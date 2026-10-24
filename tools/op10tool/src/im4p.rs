//! Extract the payload of an IM4P (Apple firmware container, DER):
//! SEQUENCE { IA5String "IM4P", IA5String type, IA5String desc, OCTET STRING payload, ... }.
//! Payload raw, or LZFSE ("bvx2"). "complzss" (old kernelcaches) is rejected.

use anyhow::{bail, ensure, Result};
use std::path::Path;

fn der(buf: &[u8], mut i: usize) -> Result<(u8, &[u8], usize)> {
    ensure!(i + 2 <= buf.len(), "DER: truncated");
    let tag = buf[i];
    let mut n = buf[i + 1] as usize;
    i += 2;
    if n & 0x80 != 0 {
        let k = n & 0x7f;
        n = buf[i..i + k].iter().fold(0usize, |a, &b| a << 8 | b as usize);
        i += k;
    }
    ensure!(i + n <= buf.len(), "DER: length past end");
    Ok((tag, &buf[i..i + n], i + n))
}

pub fn run(input: &Path, output: &Path) -> Result<()> {
    let data = std::fs::read(input)?;
    let (tag, seq, _) = der(&data, 0)?;
    ensure!(tag == 0x30, "not a DER sequence");
    let mut items = Vec::new();
    let mut i = 0;
    while i < seq.len() {
        let (t, v, j) = der(seq, i)?;
        items.push((t, v));
        i = j;
    }
    ensure!(items.first() == Some(&(0x16, &b"IM4P"[..])), "not an IM4P");
    let kind = String::from_utf8_lossy(items[1].1).into_owned();
    let Some(&(_, payload)) = items[3..].iter().find(|(t, _)| *t == 0x04) else { bail!("no payload") };
    let out = if payload.starts_with(b"complzss") {
        bail!("{kind}: complzss payload is not supported")
    } else if payload.starts_with(b"bvx2") {
        let mut v = Vec::new();
        lzfse_rust::decode_bytes(payload, &mut v)?;
        v
    } else {
        payload.to_vec()
    };
    std::fs::write(output, &out)?;
    println!("{kind}: {} bytes -> {}", out.len(), output.display());
    Ok(())
}
