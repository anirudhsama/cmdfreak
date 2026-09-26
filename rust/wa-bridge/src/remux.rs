//! Ogg/Opus → CAF remux (no transcoding). AVFoundation has no Ogg demuxer but Core Audio decodes
//! Opus-in-CAF, so voice notes are rewrapped: `OpusHead` becomes the `kuki` magic cookie, every
//! audio packet goes into `data`, and a `pakt` table carries packet sizes, the pre-skip (priming
//! frames) and the end trim derived from the final granule position.

use std::fs::File;
use std::io::{BufReader, BufWriter, Write};
use std::path::Path;

use crate::types::BridgeError;

const OPUS_RATE: f64 = 48_000.0;

#[derive(Debug)]
#[allow(dead_code)] // read through Debug when logged
pub struct RemuxStats {
    pub packets: usize,
    pub channels: u8,
    pub pre_skip: u16,
    pub valid_frames: u64,
}

pub fn remux_file(src: &Path, dst: &Path) -> Result<RemuxStats, BridgeError> {
    let reader = BufReader::new(File::open(src).map_err(io_err)?);
    let tmp = dst.with_extension("caf.part");
    let mut out = BufWriter::new(File::create(&tmp).map_err(io_err)?);
    let stats = remux(reader, &mut out)?;
    out.flush().map_err(io_err)?;
    drop(out);
    std::fs::rename(&tmp, dst).map_err(io_err)?;
    Ok(stats)
}

fn io_err(e: std::io::Error) -> BridgeError {
    BridgeError::Io(e.to_string())
}

fn bad(msg: &str) -> BridgeError {
    BridgeError::Other(format!("remux: {msg}"))
}

pub fn remux<R: std::io::Read + std::io::Seek, W: Write>(
    reader: R,
    out: &mut W,
) -> Result<RemuxStats, BridgeError> {
    let mut packets = ogg::PacketReader::new(reader);
    let read = |p: &mut ogg::PacketReader<R>| {
        p.read_packet()
            .map_err(|e| bad(&format!("ogg read: {e}")))
    };

    let head = read(&mut packets)?.ok_or_else(|| bad("empty stream"))?;
    if head.data.len() < 19 || &head.data[..8] != b"OpusHead" {
        return Err(bad("first packet is not OpusHead"));
    }
    let serial = head.stream_serial();
    let channels = head.data[9];
    let pre_skip = u16::from_le_bytes([head.data[10], head.data[11]]);
    let cookie = head.data.clone();

    let tags = read(&mut packets)?.ok_or_else(|| bad("missing OpusTags"))?;
    if !tags.data.starts_with(b"OpusTags") {
        return Err(bad("second packet is not OpusTags"));
    }

    let mut data = Vec::new();
    let mut sizes = Vec::new();
    let mut frames = Vec::new();
    let mut last_granule = 0u64;
    while let Some(p) = read(&mut packets)? {
        if p.stream_serial() != serial || p.data.is_empty() {
            continue;
        }
        frames.push(opus_packet_frames(&p.data).ok_or_else(|| bad("malformed opus packet"))?);
        sizes.push(p.data.len() as u64);
        data.extend_from_slice(&p.data);
        // Every packet reports its page's granule; the stream's end is the largest one seen
        // (u64::MAX marks a page on which no packet ends).
        let g = p.absgp_page();
        if g != u64::MAX {
            last_granule = last_granule.max(g);
        }
        if p.last_in_stream() {
            break;
        }
    }
    if sizes.is_empty() {
        return Err(bad("no audio packets"));
    }

    let total_frames: u64 = frames.iter().map(|&f| u64::from(f)).sum();
    // The final granule position is pre-skip + playable samples; anything past it is end padding.
    let valid = last_granule
        .saturating_sub(u64::from(pre_skip))
        .min(total_frames.saturating_sub(u64::from(pre_skip)));
    let remainder = total_frames - u64::from(pre_skip) - valid;
    let constant = frames.iter().all(|&f| f == frames[0]);
    let frames_per_packet = if constant { frames[0] } else { 0 };

    let mut table = Vec::with_capacity(sizes.len() * 2);
    for (size, f) in sizes.iter().zip(&frames) {
        push_varint(&mut table, *size);
        if !constant {
            push_varint(&mut table, u64::from(*f));
        }
    }

    let w = |out: &mut W, bytes: &[u8]| out.write_all(bytes).map_err(io_err);
    w(out, b"caff")?;
    w(out, &1u16.to_be_bytes())?;
    w(out, &0u16.to_be_bytes())?;

    w(out, b"desc")?;
    w(out, &32i64.to_be_bytes())?;
    w(out, &OPUS_RATE.to_be_bytes())?;
    w(out, b"opus")?;
    w(out, &0u32.to_be_bytes())?; // format flags
    w(out, &0u32.to_be_bytes())?; // bytes per packet (variable)
    w(out, &frames_per_packet.to_be_bytes())?;
    w(out, &u32::from(channels).to_be_bytes())?;
    w(out, &0u32.to_be_bytes())?; // bits per channel

    w(out, b"kuki")?;
    w(out, &(cookie.len() as i64).to_be_bytes())?;
    w(out, &cookie)?;

    w(out, b"pakt")?;
    w(out, &((24 + table.len()) as i64).to_be_bytes())?;
    w(out, &(sizes.len() as i64).to_be_bytes())?;
    w(out, &(valid as i64).to_be_bytes())?;
    w(out, &i32::from(pre_skip).to_be_bytes())?;
    w(out, &(remainder as i32).to_be_bytes())?;
    w(out, &table)?;

    w(out, b"data")?;
    w(out, &((4 + data.len()) as i64).to_be_bytes())?;
    w(out, &0u32.to_be_bytes())?; // edit count
    w(out, &data)?;

    Ok(RemuxStats { packets: sizes.len(), channels, pre_skip, valid_frames: valid })
}

/// Samples (at 48 kHz) in one Opus packet, from its TOC byte (RFC 6716 §3.1).
pub fn opus_packet_frames(packet: &[u8]) -> Option<u32> {
    let toc = *packet.first()?;
    let config = toc >> 3;
    let frame = match config {
        0..=11 => [480, 960, 1920, 2880][usize::from(config % 4)],
        12..=15 => [480, 960][usize::from(config % 2)],
        _ => [120, 240, 480, 960][usize::from(config % 4)],
    };
    let count = match toc & 0x3 {
        0 => 1,
        1 | 2 => 2,
        _ => u32::from(*packet.get(1)? & 0x3F),
    };
    Some(frame * count)
}

/// CAF variable-length integer: big-endian 7-bit groups, high bit set on all but the last.
fn push_varint(buf: &mut Vec<u8>, mut v: u64) {
    let mut tmp = [0u8; 10];
    let mut i = tmp.len();
    loop {
        i -= 1;
        tmp[i] = (v & 0x7F) as u8;
        v >>= 7;
        if v == 0 {
            break;
        }
    }
    let last = tmp.len() - 1;
    for (j, b) in tmp.iter_mut().enumerate().skip(i) {
        if j != last {
            *b |= 0x80;
        }
    }
    buf.extend_from_slice(&tmp[i..]);
}

#[cfg(test)]
mod tests {
    use super::*;
    use ogg::writing::{PacketWriteEndInfo, PacketWriter};
    use std::io::Cursor;

    fn opus_head(pre_skip: u16) -> Vec<u8> {
        let mut h = b"OpusHead".to_vec();
        h.push(1); // version
        h.push(1); // channels
        h.extend_from_slice(&pre_skip.to_le_bytes());
        h.extend_from_slice(&48_000u32.to_le_bytes());
        h.extend_from_slice(&0i16.to_le_bytes());
        h.push(0); // mapping family
        h
    }

    /// Builds an Ogg stream of 20 ms SILK packets (config 1, code 0 → 960 samples each).
    fn fake_ogg(packets: usize, pre_skip: u16, trim: u64) -> Vec<u8> {
        let mut buf = Vec::new();
        let mut w = PacketWriter::new(&mut buf);
        w.write_packet(opus_head(pre_skip), 7, PacketWriteEndInfo::EndPage, 0).unwrap();
        w.write_packet(b"OpusTags\0\0\0\0\0\0\0\0".to_vec(), 7, PacketWriteEndInfo::EndPage, 0)
            .unwrap();
        for i in 0..packets {
            let last = i + 1 == packets;
            let granule = (i as u64 + 1) * 960 - if last { trim } else { 0 };
            let data = vec![0x08, i as u8, 0xAA, 0xBB];
            let end = if last { PacketWriteEndInfo::EndStream } else { PacketWriteEndInfo::EndPage };
            w.write_packet(data, 7, end, granule).unwrap();
        }
        buf
    }

    #[test]
    fn toc_frame_sizes() {
        assert_eq!(opus_packet_frames(&[0x08]), Some(960)); // SILK 20ms
        assert_eq!(opus_packet_frames(&[0x18]), Some(2880)); // SILK 60ms
        assert_eq!(opus_packet_frames(&[0xF8]), Some(960)); // CELT 20ms
        assert_eq!(opus_packet_frames(&[0x09]), Some(1920)); // two 20ms frames
        assert_eq!(opus_packet_frames(&[0x0B, 0x03]), Some(2880)); // code 3, three frames
    }

    #[test]
    fn varint_encoding() {
        let mut b = Vec::new();
        push_varint(&mut b, 5);
        push_varint(&mut b, 200);
        push_varint(&mut b, 16384);
        assert_eq!(b, vec![5, 0x81, 0x48, 0x81, 0x80, 0x00]);
    }

    #[test]
    fn remux_writes_caf_with_cookie_and_packet_table() {
        let ogg = fake_ogg(10, 312, 100);
        let mut out = Vec::new();
        let stats = remux(Cursor::new(ogg), &mut out).unwrap();
        assert_eq!(stats.packets, 10);
        assert_eq!(stats.pre_skip, 312);
        assert_eq!(stats.valid_frames, 9600 - 100 - 312);

        assert_eq!(&out[..4], b"caff");
        let find = |tag: &[u8]| out.windows(4).position(|w| w == tag).unwrap();
        let desc = find(b"desc");
        assert_eq!(&out[desc + 20..desc + 24], b"opus");
        let fpp = u32::from_be_bytes(out[desc + 32..desc + 36].try_into().unwrap());
        assert_eq!(fpp, 960);
        let kuki = find(b"kuki");
        assert_eq!(&out[kuki + 12..kuki + 20], b"OpusHead");
        let pakt = find(b"pakt");
        let n = i64::from_be_bytes(out[pakt + 12..pakt + 20].try_into().unwrap());
        let valid = i64::from_be_bytes(out[pakt + 20..pakt + 28].try_into().unwrap());
        let priming = i32::from_be_bytes(out[pakt + 28..pakt + 32].try_into().unwrap());
        let remainder = i32::from_be_bytes(out[pakt + 32..pakt + 36].try_into().unwrap());
        assert_eq!((n, valid, priming, remainder), (10, 9188, 312, 100));
        let data = find(b"data");
        let size = i64::from_be_bytes(out[data + 4..data + 12].try_into().unwrap());
        assert_eq!(size, 4 + 40);
        assert_eq!(out.len(), data + 12 + size as usize);
    }

    #[test]
    fn rejects_non_opus() {
        let mut buf = Vec::new();
        let mut w = PacketWriter::new(&mut buf);
        w.write_packet(b"\x01vorbis-ish-header".to_vec(), 1, PacketWriteEndInfo::EndStream, 0)
            .unwrap();
        assert!(remux(Cursor::new(buf), &mut Vec::new()).is_err());
    }
}
