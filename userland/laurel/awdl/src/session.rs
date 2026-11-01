//! One session: the Node between the kernel's vdev and awdl0.
use std::collections::VecDeque;
use std::time::{Duration, Instant};

use laurel_awdld::policy::{self, Proof};
use laurel_awdld::proxy::{self, Outbound};
use laurel_awdld::wifi;
use owly_awdl::frame::Frame;
use owly_awdl::{Action, Channel, Config, Input, Ipv6Packet, MacAddr, Node, Presence, RadioConstraints, Time};

use crate::ctl::{self, Ctl};
use crate::run::{End, everyone, if_up_body, modem_stopped, say, set_proof};

const MSG_STOP: u8 = 2;
const MSG_TX_MGMT: u8 = 3;
const MSG_TX_DATA: u8 = 4;
const MSG_PEER_ADD: u8 = 5;
const MSG_PEER_DEL: u8 = 6;
const MSG_IF_UP: u8 = 7;
const MSG_IP_IN: u8 = 8;
const EV_RX_MGMT: u8 = 0x81;
const EV_RX_DATA: u8 = 0x82;
const EV_IP_OUT: u8 = 0x83;
const LINGER_S: u64 = 30;
const UNICAST_HOLD_US: u64 = 2_000_000; // as owly-awdl's driver
const RETRY_US: u64 = 100_000;
const ANNOUNCE_S: u64 = 3;

fn transmit(ctl: &Ctl, frame: Frame, at: Time, node: &Node, now: Time, held: &mut VecDeque<(Time, Frame)>, retrying: bool) {
    if frame.is_action() {
        let _ = ctl.send(MSG_TX_MGMT, &frame.bytes); // built for this moment: a full queue loses it, and the next one is near
        return;
    }
    if retrying && (now.since(at) > UNICAST_HOLD_US || (frame.to.is_multicast() && (now.since(at) > RETRY_US || !node.may_send(frame.to, now)))) {
        return;
    }
    if ctl.send(MSG_TX_DATA, &frame.bytes).is_err() {
        held.push_back((at, frame));
    }
}

pub(crate) fn run_node(ctl: &Ctl, mac: MacAddr, host: &str, freq: u16, share: bool, before: Proof, typed: bool) -> End {
    let end = node_loop(ctl, mac, host, freq, share, before, typed);
    ctl::if_down(); // no radio under awdl0 now; the next session brings it up
    end
}

fn node_loop(ctl: &Ctl, mac: MacAddr, host: &str, freq: u16, share: bool, before: Proof, typed: bool) -> End {
    let channel = Channel(owly_channel(freq));
    let presence = if share { Presence::Share } else { Presence::Fixed };
    let mut cfg = Config::new(mac, host, RadioConstraints { channel, presence });
    cfg.max_frame = 2000;
    cfg.rssi_threshold = Some(-80); // a phone's small antenna
    let epoch = Instant::now();
    let time = |e: Instant| Time(e.elapsed().as_micros() as u64 + 1);
    let mut node = Node::new(cfg, time(epoch));
    let mut timer = Time(1);
    let mut held: VecDeque<(Time, Frame)> = VecDeque::new();
    let mut peers: Vec<(MacAddr, String)> = Vec::new();
    let mut buf = vec![0u8; 2100];
    let mut frame = Vec::with_capacity(2100);
    let mut if_up = false;
    let mut heard_any = false;
    let mut proved = false;
    let (mut last_st, mut last_announce, mut last_wanted) = (Instant::now(), Instant::now(), Instant::now());
    let mut last_peer = Instant::now();
    say(&format!("on: AWDL node up on channel {} ({})", channel.0, if share { "beside en0" } else { "alone" }));
    let mut inputs: Vec<Action> = node.handle(Input::Timer(time(epoch))).collect();
    loop {
        for a in inputs.drain(..) {
            match a {
                Action::Transmit { at, frame: f } => {
                    let now = time(epoch);
                    transmit(ctl, f, at, &node, now, &mut held, false);
                }
                Action::ArmTimer(t) => timer = t,
                Action::PeerUp(p) => {
                    say(&format!("on: AWDL peer {} class {}: {}", p.mac, p.devclass, p.name));
                    let _ = ctl.send(MSG_PEER_ADD, &p.mac.0);
                    peers.push((p.mac, p.name));
                    last_peer = Instant::now();
                }
                Action::PeerDown(m) => {
                    let _ = ctl.send(MSG_PEER_DEL, &m.0);
                    peers.retain(|(x, _)| *x != m);
                }
                Action::Deliver(p) => {
                    let _ = ctl.send(MSG_IP_IN, &p.to_ethernet());
                }
            }
        }
        let now = time(epoch);
        let wait_ms = (timer.0.saturating_sub(now.0) / 1000).clamp(0, 20) as i32;
        if wait_ms > 0 {
            ctl.wait(wait_ms);
        }
        // the kernel's messages
        for _ in 0..64 {
            let n = match ctl.recv(&mut buf) {
                Ok(Some(n)) => n,
                Ok(None) => break,
                Err(e) => {
                    say(&format!("off: the kernel's socket failed: {e}"));
                    return End::Fatal;
                }
            };
            if n < 4 {
                continue;
            }
            let now = time(epoch);
            match buf[0] {
                EV_RX_MGMT | EV_RX_DATA => {
                    if wifi::normalize_rx(&buf[4..n], &mut frame).is_none() {
                        continue;
                    }
                    heard_any = true;
                    let rssi = if buf[0] == EV_RX_MGMT { Some(buf[1] as i8) } else { None };
                    inputs.extend(node.handle(Input::Frame { rx_time: now, rssi, bytes: &frame }));
                }
                EV_IP_OUT => match proxy::outbound(&buf[4..n], mac) {
                    Outbound::Send => {
                        if let Some(packet) = Ipv6Packet::from_ethernet(&buf[4..n]) {
                            inputs.extend(node.handle(Input::Outbound { now, packet }));
                        }
                    }
                    Outbound::Drop => {}
                    Outbound::Answer(a) => {
                        let _ = ctl.send(MSG_IP_IN, &a);
                    }
                },
                _ => {}
            }
        }
        let now = time(epoch);
        if now.0 >= timer.0 {
            inputs.extend(node.handle(Input::Timer(now)));
        }
        for _ in 0..held.len() {
            let (at, f) = held.pop_front().unwrap();
            transmit(ctl, f, at, &node, now, &mut held, true);
        }
        // awdl0 only when AWDL has been heard: no frames, no interface
        if heard_any && !if_up {
            if_up = true;
            match ctl.send(MSG_IF_UP, &if_up_body(mac, typed)).and_then(|()| ctl::ipv6_up()) {
                Ok(()) => say("on: awdl0 up with its link-local address"),
                Err(e) => {
                    say(&format!("off: awdl0: {e}"));
                    let _ = ctl.send(MSG_STOP, &[]);
                    return End::Refused;
                }
            }
        }
        if if_up && last_announce.elapsed() >= Duration::from_secs(ANNOUNCE_S) {
            last_announce = Instant::now();
            for (m, name) in &peers {
                let _ = ctl.send(MSG_IP_IN, &proxy::announce(*m, name));
            }
        }
        if last_st.elapsed() >= Duration::from_secs(1) {
            last_st = Instant::now();
            let st = ctl.status().unwrap_or_default();
            if st.fw_fatal != 0 {
                return modem_stopped(&st);
            }
            if !proved && epoch.elapsed() >= Duration::from_secs(policy::PROOF_S) {
                proved = true;
                let _ = set_proof(if share || before == Proof::SharedOk { Proof::SharedOk } else { Proof::AloneOk });
            }
            if st.state != ctl::STATE_UP {
                return End::Stop; // the kernel has ended it: en0 was first; it said so
            }
            if policy::wanted(everyone(), st.ble_age_s) {
                last_wanted = Instant::now();
            } else if last_wanted.elapsed() >= Duration::from_secs(LINGER_S) && peers.is_empty() {
                let _ = ctl.send(MSG_STOP, &[]);
                say(&format!("off: AirDrop is not in use: rx {} mgmt {} data, tx {} mgmt {} data, full {}", st.rx_mgmt, st.rx_data, st.tx_mgmt, st.tx_data, st.tx_full));
                wait_off(ctl);
                return End::Stop;
            }
            if !share && !heard_any && last_peer.elapsed() >= Duration::from_secs(policy::NO_PEER_ROTATE_S) {
                let _ = ctl.send(MSG_STOP, &[]);
                wait_off(ctl);
                return End::NoPeers; // the next social channel: a peer's 5 GHz channel may be the other one
            }
        }
    }
}

fn wait_off(ctl: &Ctl) {
    for _ in 0..40 {
        if ctl.status().map(|s| s.state == ctl::STATE_OFF).unwrap_or(true) {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn owly_channel(freq: u16) -> u8 {
    if freq < 4000 { ((freq - 2407) / 5) as u8 } else { ((freq - 5000) / 5) as u8 }
}
