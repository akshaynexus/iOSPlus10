//! What the IP stack needs on `awdl0` that does not exist on AWDL:
//!
//! - Neighbor Discovery. AWDL carries none (NET-2): a peer's link-local address gives its MAC. The kernel sends a solicitation; the answer comes from here.
//! - mDNS for a sending sharingd. An iPhone's records travel in the Service Response TLV, its mDNS does not reach a non-Apple node (Owly docs/implementation.md, DISC-5).
//!   So each valid peer gets a `_airdrop._tcp` record here; sharingd then posts `/Discover` to it, and the peer's answer decides what is listed.

use owly_awdl::MacAddr;

const ETH_IPV6: [u8; 2] = [0x86, 0xdd];
const ICMPV6: u8 = 58;
const UDP: u8 = 17;

/// What to do with a frame from the IP stack.
#[derive(Debug, PartialEq, Eq)]
pub enum Outbound {
    /// Over the air.
    Send,
    /// Not for AWDL: Router Solicitation, MLD, a neighbor question with no peer.
    Drop,
    /// Answer the stack with this frame.
    Answer(Vec<u8>),
}

pub fn outbound(frame: &[u8], own: MacAddr) -> Outbound {
    if frame.len() < 14 + 40 || frame[12..14] != ETH_IPV6 {
        return Outbound::Drop;
    }
    if frame[14 + 6] != ICMPV6 {
        // a hop-by-hop header means MLD: there is no router on AWDL
        return if frame[14 + 6] == 0 { Outbound::Drop } else { Outbound::Send };
    }
    let icmp = &frame[14 + 40..];
    match icmp.first() {
        Some(133) | Some(143) => Outbound::Drop,
        Some(135) if icmp.len() >= 24 => {
            let target: [u8; 16] = icmp[8..24].try_into().unwrap();
            match mac_of(&target) {
                Some(mac) if mac != own => Outbound::Answer(neighbor_advert(frame, &target, mac)),
                _ => Outbound::Drop, // our own DAD, or not link-local
            }
        }
        _ => Outbound::Send,
    }
}

fn mac_of(ll: &[u8; 16]) -> Option<MacAddr> {
    if ll[0] != 0xfe || ll[1] != 0x80 || ll[11] != 0xff || ll[12] != 0xfe {
        return None;
    }
    Some(MacAddr([ll[8] ^ 2, ll[9], ll[10], ll[13], ll[14], ll[15]]))
}

fn link_local(mac: MacAddr) -> [u8; 16] {
    let m = mac.0;
    [0xfe, 0x80, 0, 0, 0, 0, 0, 0, m[0] ^ 2, m[1], m[2], 0xff, 0xfe, m[3], m[4], m[5]]
}

fn sum(mut acc: u32, data: &[u8]) -> u32 {
    let mut it = data.chunks_exact(2);
    for c in &mut it {
        acc += u32::from(u16::from_be_bytes([c[0], c[1]]));
    }
    if let [b] = it.remainder() {
        acc += u32::from(*b) << 8;
    }
    acc
}

fn checksum(src: &[u8; 16], dst: &[u8; 16], proto: u8, body: &[u8]) -> u16 {
    let mut acc = sum(0, src);
    acc = sum(acc, dst);
    acc += body.len() as u32 + u32::from(proto);
    acc = sum(acc, body);
    while acc >> 16 != 0 {
        acc = (acc & 0xffff) + (acc >> 16);
    }
    !(acc as u16)
}

fn ipv6(dst_mac: [u8; 6], src_mac: MacAddr, src: &[u8; 16], dst: &[u8; 16], proto: u8, hop: u8, body: &[u8]) -> Vec<u8> {
    let mut f = Vec::with_capacity(14 + 40 + body.len());
    f.extend_from_slice(&dst_mac);
    f.extend_from_slice(&src_mac.0);
    f.extend_from_slice(&ETH_IPV6);
    f.extend_from_slice(&[0x60, 0, 0, 0]);
    f.extend_from_slice(&(body.len() as u16).to_be_bytes());
    f.push(proto);
    f.push(hop);
    f.extend_from_slice(src);
    f.extend_from_slice(dst);
    f.extend_from_slice(body);
    f
}

/// The peer's answer: Solicited + Override, with its MAC. Sent to the asker.
fn neighbor_advert(question: &[u8], target: &[u8; 16], mac: MacAddr) -> Vec<u8> {
    let asker_mac: [u8; 6] = question[6..12].try_into().unwrap();
    let asker_ip: [u8; 16] = question[14 + 8..14 + 24].try_into().unwrap();
    let mut icmp = vec![136, 0, 0, 0, 0x60, 0, 0, 0];
    icmp.extend_from_slice(target);
    icmp.extend_from_slice(&[2, 1]);
    icmp.extend_from_slice(&mac.0);
    let c = checksum(target, &asker_ip, ICMPV6, &icmp);
    icmp[2..4].copy_from_slice(&c.to_be_bytes());
    ipv6(asker_mac, mac, target, &asker_ip, ICMPV6, 255, &icmp)
}

fn name(out: &mut Vec<u8>, labels: &[&str]) {
    for l in labels {
        out.push(l.len() as u8);
        out.extend_from_slice(l.as_bytes());
    }
    out.push(0);
}

fn rr(out: &mut Vec<u8>, labels: &[&str], rtype: u16, ttl: u32, data: &[u8]) {
    name(out, labels);
    out.extend_from_slice(&rtype.to_be_bytes());
    out.extend_from_slice(&0x8001u16.to_be_bytes()); // IN + cache flush
    out.extend_from_slice(&ttl.to_be_bytes());
    out.extend_from_slice(&(data.len() as u16).to_be_bytes());
    out.extend_from_slice(data);
}

/// A receiver's flags in its TXT record: 0x3fb, the macOS default (OpenDrop config.py, from sharingd). Only the answer to `/Discover` decides what is listed.
const AIRDROP_FLAGS: &str = "flags=1019";
const AIRDROP_PORT: u16 = 8770;

/// One multicast mDNS answer for a peer: PTR, SRV, TXT, AAAA, as if it came from that peer. TTL 10 s: the record goes by itself when the peer does.
pub fn announce(peer: MacAddr, host: &str) -> Vec<u8> {
    let m = peer.0;
    let instance = format!("{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}", m[0], m[1], m[2], m[3], m[4], m[5]);
    let host = sanitize(host, &instance);
    let mut d = vec![0, 0, 0x84, 0, 0, 0, 0, 4, 0, 0, 0, 0]; // id 0, response, 4 answers
    let mut ptr = Vec::new();
    name(&mut ptr, &[&instance, "_airdrop", "_tcp", "local"]);
    rr(&mut d, &["_airdrop", "_tcp", "local"], 12, 10, &ptr);
    let d_len = d.len();
    d[d_len - ptr.len() - 8] = 0; // a shared record: no cache-flush bit on the PTR's class
    let mut srv = vec![0, 0, 0, 0];
    srv.extend_from_slice(&AIRDROP_PORT.to_be_bytes());
    name(&mut srv, &[&host, "local"]);
    rr(&mut d, &[&instance, "_airdrop", "_tcp", "local"], 33, 10, &srv);
    let mut txt = vec![AIRDROP_FLAGS.len() as u8];
    txt.extend_from_slice(AIRDROP_FLAGS.as_bytes());
    rr(&mut d, &[&instance, "_airdrop", "_tcp", "local"], 16, 10, &txt);
    let ll = link_local(peer);
    rr(&mut d, &[&host, "local"], 28, 10, &ll);
    let mut udp = Vec::with_capacity(8 + d.len());
    udp.extend_from_slice(&5353u16.to_be_bytes());
    udp.extend_from_slice(&5353u16.to_be_bytes());
    udp.extend_from_slice(&((8 + d.len()) as u16).to_be_bytes());
    udp.extend_from_slice(&[0, 0]);
    udp.extend_from_slice(&d);
    let group: [u8; 16] = [0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xfb];
    let c = checksum(&ll, &group, UDP, &udp);
    udp[6..8].copy_from_slice(&c.to_be_bytes());
    ipv6([0x33, 0x33, 0, 0, 0, 0xfb], peer, &ll, &group, UDP, 255, &udp)
}

fn sanitize(host: &str, fallback: &str) -> String {
    let h: String = host.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').take(40).collect();
    if h.is_empty() { fallback.to_string() } else { h }
}

#[cfg(test)]
mod tests;
