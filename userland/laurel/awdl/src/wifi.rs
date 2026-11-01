//! The kernel's frames into the form owly-awdl reads.
//!
//! HTT Rx here is native wifi (rx decap 1 at WMI INIT): the firmware has split an A-MSDU already, and a QoS frame keeps its QoS field,
//! padded so that the header takes 28 bytes (ath10k_htt_rx_nwifi_hdrlen). owly-awdl reads a frame from its MAC header on: a data frame
//! with a QoS field of 2 bytes and an A-MSDU flag. So a QoS frame becomes a plain data frame.

/// The frame for `Input::Frame`, in `out`. `None`: a frame with no room for its header.
pub fn normalize_rx(frame: &[u8], out: &mut Vec<u8>) -> Option<()> {
    if frame.len() < 24 {
        return None;
    }
    out.clear();
    let is_data = frame[0] & 0x0C == 0x08;
    let is_qos = is_data && frame[0] & 0x80 != 0;
    if !is_qos {
        out.extend_from_slice(frame);
        return Some(());
    }
    if frame.len() < 28 {
        return None;
    }
    out.extend_from_slice(&frame[..24]);
    out[0] &= !0x80; // QoS data to data
    out.extend_from_slice(&frame[28..]);
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use owly_awdl::frame::{self, Received};
    use owly_awdl::{BSSID, MacAddr};

    fn data(fc0: u8) -> Vec<u8> {
        let mut f = vec![fc0, 0];
        f.extend_from_slice(&[0, 0]);
        f.extend_from_slice(&[0x02, 1, 2, 3, 4, 5]);
        f.extend_from_slice(&[0x02, 9, 9, 9, 9, 9]);
        f.extend_from_slice(&BSSID.0);
        f.extend_from_slice(&[0x10, 0]);
        f
    }

    #[test]
    fn qos_frame_becomes_plain_data() {
        let mut f = data(0x88);
        f.extend_from_slice(&[0x80, 0, 0, 0]); // QoS field with the A-MSDU bit, 2 bytes of pad: already split by the firmware
        f.extend_from_slice(&[0xAA, 0xAA, 0x03]);
        let mut out = Vec::new();
        normalize_rx(&f, &mut out).unwrap();
        assert_eq!(out[0], 0x08);
        assert_eq!(&out[24..], &[0xAA, 0xAA, 0x03]);
        match frame::parse(&out).unwrap() {
            Received::Data { header, amsdu, body } => {
                assert!(!amsdu);
                assert_eq!(header.src, MacAddr([0x02, 9, 9, 9, 9, 9]));
                assert_eq!(body, &[0xAA, 0xAA, 0x03]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn plain_and_short_frames() {
        let f = data(0x08);
        let mut out = Vec::new();
        normalize_rx(&f, &mut out).unwrap();
        assert_eq!(out, f);
        assert!(normalize_rx(&f[..20], &mut out).is_none());
        let mut short = data(0x88);
        short.extend_from_slice(&[0, 0]); // a QoS field, no padding
        assert!(normalize_rx(&short, &mut out).is_none());
    }
}
