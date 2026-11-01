//! Two nodes configured as the daemon does, with the air replaced by what the kernel gives: action frames as they are, data frames in native-wifi form
//! (QoS field, padded to 28 bytes) through wifi::normalize_rx. Host only; it proves the daemon's use of owly-awdl, not the radio.
use laurel_awdld::wifi;
use owly_awdl::{Action, Channel, Config, Input, Ipv6Packet, MacAddr, Node, Presence, RadioConstraints, Time};

fn config(mac: MacAddr, name: &str, presence: Presence) -> Config {
    let mut c = Config::new(mac, name, RadioConstraints { channel: Channel(44), presence });
    c.max_frame = 2000;
    c.rssi_threshold = Some(-80);
    c
}

/// As the kernel's HTT Rx ring hands a data frame up.
fn native_wifi(bytes: &[u8]) -> Vec<u8> {
    if bytes[0] & 0x0C != 0x08 {
        return bytes.to_vec();
    }
    let mut f = bytes[..24].to_vec();
    f[0] |= 0x80;
    f.extend_from_slice(&[0, 0, 0, 0]);
    f.extend_from_slice(&bytes[24..]);
    f
}

struct Side {
    node: Node,
    timer: Time,
    air: Vec<Vec<u8>>,
    up: Vec<MacAddr>,
    delivered: Vec<Ipv6Packet>,
}

impl Side {
    fn new(cfg: Config) -> Side {
        Side { node: Node::new(cfg, Time(1)), timer: Time(1), air: Vec::new(), up: Vec::new(), delivered: Vec::new() }
    }

    fn handle(&mut self, input: Input) {
        let actions: Vec<Action> = self.node.handle(input).collect();
        for a in actions {
            match a {
                Action::Transmit { frame, .. } => self.air.push(frame.bytes),
                Action::ArmTimer(t) => self.timer = t,
                Action::PeerUp(p) => self.up.push(p.mac),
                Action::PeerDown(m) => self.up.retain(|x| *x != m),
                Action::Deliver(p) => self.delivered.push(p),
            }
        }
    }
}

fn pass(from: &mut Side, to: &mut Side, now: Time, scratch: &mut Vec<u8>) {
    for f in std::mem::take(&mut from.air) {
        let n = native_wifi(&f);
        wifi::normalize_rx(&n, scratch).unwrap();
        to.handle(Input::Frame { rx_time: now, rssi: Some(-50), bytes: scratch });
    }
}

#[test]
fn peers_meet_and_ipv6_crosses_in_native_wifi_form() {
    let (ma, mb) = (MacAddr([0x02, 1, 1, 1, 1, 1]), MacAddr([0x02, 2, 2, 2, 2, 2]));
    let mut a = Side::new(config(ma, "mia3", Presence::Fixed));
    let mut b = Side::new(config(mb, "iphone", Presence::Fixed));
    a.handle(Input::Timer(Time(1)));
    b.handle(Input::Timer(Time(1)));
    let mut scratch = Vec::new();
    let mut sent = false;
    for ms in 1..20_000u64 {
        let now = Time(ms * 1000);
        if now.0 >= a.timer.0 {
            a.handle(Input::Timer(now));
        }
        if now.0 >= b.timer.0 {
            b.handle(Input::Timer(now));
        }
        pass(&mut a, &mut b, now, &mut scratch);
        pass(&mut b, &mut a, now, &mut scratch);
        if !sent && a.up.contains(&mb) && b.up.contains(&ma) {
            // a real TCP-like packet from a to b: link-local to link-local
            let mut ip = vec![0x60, 0, 0, 0, 0, 4, 59, 64];
            ip.extend_from_slice(&ma.link_local().octets());
            ip.extend_from_slice(&mb.link_local().octets());
            ip.extend_from_slice(&[1, 2, 3, 4]);
            let packet = Ipv6Packet::from_ip(ip).expect("link-local addresses give MACs");
            a.handle(Input::Outbound { now, packet });
            sent = true;
        }
        if !b.delivered.is_empty() {
            break;
        }
    }
    assert!(a.up.contains(&mb), "a never took b as a peer");
    assert!(b.up.contains(&ma), "b never took a as a peer");
    assert!(sent);
    let got = b.delivered.first().expect("the packet did not cross");
    assert_eq!(&got.data[got.data.len() - 4..], &[1, 2, 3, 4]);
    assert_eq!(got.src, ma);
}
