use super::*;

const OWN: MacAddr = MacAddr([0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]);
const PEER: MacAddr = MacAddr([0x5e, 0x8f, 0xa4, 0x8e, 0x3e, 0x84]);

fn solicitation(target: &[u8; 16]) -> Vec<u8> {
    let mut icmp = vec![135, 0, 0, 0, 0, 0, 0, 0];
    icmp.extend_from_slice(target);
    let src = link_local(OWN);
    let dst = [0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, target[13], target[14], target[15]];
    ipv6([0x33, 0x33, 0xff, target[13], target[14], target[15]], OWN, &src, &dst, ICMPV6, 255, &icmp)
}

fn upper_ok(frame: &[u8]) -> bool {
    let src: [u8; 16] = frame[22..38].try_into().unwrap();
    let dst: [u8; 16] = frame[38..54].try_into().unwrap();
    let mut acc = sum(0, &src);
    acc = sum(acc, &dst);
    acc += (frame.len() - 54) as u32 + u32::from(frame[20]);
    acc = sum(acc, &frame[54..]);
    while acc >> 16 != 0 {
        acc = (acc & 0xffff) + (acc >> 16);
    }
    acc as u16 == 0xffff
}

#[test]
fn link_local_round_trip_matches_owly() {
    assert_eq!(std::net::Ipv6Addr::from(link_local(PEER)), PEER.link_local());
    assert_eq!(mac_of(&link_local(PEER)), Some(PEER));
    assert_eq!(mac_of(&[0x20; 16]), None);
}

#[test]
fn a_question_for_a_peer_is_answered_here() {
    let target = link_local(PEER);
    let Outbound::Answer(a) = outbound(&solicitation(&target), OWN) else { panic!() };
    assert_eq!(&a[0..6], &OWN.0);
    assert_eq!(&a[6..12], &PEER.0);
    assert_eq!(a[20], ICMPV6);
    assert_eq!(a[54], 136);
    assert_eq!(&a[62..78], &target);
    assert_eq!(&a[78..80], &[2, 1]);
    assert_eq!(&a[80..86], &PEER.0);
    assert!(upper_ok(&a));
}

#[test]
fn what_stays_off_the_air() {
    let own = link_local(OWN);
    assert_eq!(outbound(&solicitation(&own), OWN), Outbound::Drop); // our own DAD
    let mut mld = solicitation(&link_local(PEER));
    mld[54] = 143;
    assert_eq!(outbound(&mld, OWN), Outbound::Drop);
    let mut rs = solicitation(&link_local(PEER));
    rs[54] = 133;
    assert_eq!(outbound(&rs, OWN), Outbound::Drop);
    let mut hop = solicitation(&link_local(PEER));
    hop[20] = 0;
    assert_eq!(outbound(&hop, OWN), Outbound::Drop);
    assert_eq!(outbound(&[0; 20], OWN), Outbound::Drop);
}

#[test]
fn tcp_and_echo_go_out() {
    let mut f = solicitation(&link_local(PEER));
    f[54] = 128;
    assert_eq!(outbound(&f, OWN), Outbound::Send);
    f[20] = 6;
    assert_eq!(outbound(&f, OWN), Outbound::Send);
}

#[test]
fn an_announcement_is_valid_mdns() {
    let f = announce(PEER, "Johns iPhone");
    assert_eq!(&f[0..6], &[0x33, 0x33, 0, 0, 0, 0xfb]);
    assert_eq!(f[20], UDP);
    assert_eq!(f[21], 255);
    assert!(upper_ok(&f));
    let d = &f[54 + 8..];
    assert_eq!(&d[..12], &[0, 0, 0x84, 0, 0, 0, 0, 4, 0, 0, 0, 0]);
    // the PTR first: _airdrop._tcp.local, type 12, class IN without the flush bit
    let n = b"\x08_airdrop\x04_tcp\x05local\x00";
    assert_eq!(&d[12..12 + n.len()], n);
    let p = 12 + n.len();
    assert_eq!(&d[p..p + 4], &[0, 12, 0, 1]);
    assert!(f.windows(10).any(|w| w == b"flags=1019"));
    assert!(f.windows(10).any(|w| w == b"JohnsiPhon"));
    assert!(f.windows(12).any(|w| w == b"5e8fa48e3e84"));
    assert!(f.windows(16).any(|w| w == link_local(PEER)));
}

#[test]
fn an_empty_host_name_falls_back() {
    let f = announce(PEER, "!!");
    assert!(upper_ok(&f));
}
