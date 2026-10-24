//! Extract the payload of an IM4P (Apple firmware container, DER, parsed with `simple_asn1`):
//! SEQUENCE { IA5String "IM4P", IA5String type, IA5String desc, OCTET STRING payload, ... }.
//! Payload raw, or LZFSE ("bvx2", decoded with `lzfse_rust`). "complzss" is rejected.

use anyhow::{anyhow, bail, Result};
use simple_asn1::{from_der, ASN1Block};
use std::path::Path;

pub fn run(input: &Path, output: &Path) -> Result<()> {
    let data = std::fs::read(input)?;
    let blocks = from_der(&data).map_err(|e| anyhow!("DER: {e:?}"))?;
    let Some(ASN1Block::Sequence(_, items)) = blocks.first() else { bail!("not a DER sequence") };
    let text = |i: usize| match items.get(i) { Some(ASN1Block::IA5String(_, s)) => Some(s.clone()), _ => None };
    if text(0).as_deref() != Some("IM4P") { bail!("not an IM4P"); }
    let kind = text(1).unwrap_or_default();
    let payload = items.iter().skip(3).find_map(|b| match b { ASN1Block::OctetString(_, v) => Some(v), _ => None })
        .ok_or_else(|| anyhow!("no payload"))?;
    let out = if payload.starts_with(b"complzss") {
        bail!("{kind}: complzss payload is not supported")
    } else if payload.starts_with(b"bvx2") {
        let mut v = Vec::new();
        lzfse_rust::decode_bytes(payload, &mut v)?;
        v
    } else {
        payload.clone()
    };
    std::fs::write(output, &out)?;
    println!("{kind}: {} bytes -> {}", out.len(), output.display());
    Ok(())
}
