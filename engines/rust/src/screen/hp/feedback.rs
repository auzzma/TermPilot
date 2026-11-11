use std::{
    collections::HashMap,
    time::{Instant, SystemTime, UNIX_EPOCH},
};
pub fn fir(sender: u32, target: u32, sequence: u8) -> Vec<u8> {
    let mut out = vec![0x80, 201, 0, 1];
    out.extend(sender.to_be_bytes());
    out.extend([0x84, 206, 0, 4]);
    out.extend(sender.to_be_bytes());
    out.extend([0; 4]);
    out.extend(target.to_be_bytes());
    out.extend([sequence, 0, 0, 0]);
    out.extend([0x81, 206, 0, 2]);
    out.extend(sender.to_be_bytes());
    out.extend(target.to_be_bytes());
    out.extend([0x80, 192, 0, 1]);
    out.extend(target.to_be_bytes());
    out
}
pub fn nack(sender: u32, target: u32, missing: &[u16]) -> Vec<u8> {
    let mut fields = Vec::new();
    let mut i = 0;
    while i < missing.len() && fields.len() < 2048 {
        let pid = missing[i];
        i += 1;
        let mut mask = 0u16;
        while i < missing.len() {
            let delta = missing[i].wrapping_sub(pid);
            if !(1..=16).contains(&delta) {
                break;
            }
            mask |= 1 << (delta - 1);
            i += 1;
        }
        fields.extend(pid.to_be_bytes());
        fields.extend(mask.to_be_bytes());
    }
    let mut out = vec![0x81, 205];
    out.extend((2 + fields.len() as u16 / 4).to_be_bytes());
    out.extend(sender.to_be_bytes());
    out.extend(target.to_be_bytes());
    out.extend(fields);
    out
}
pub fn ack(sender: u32, donl: u16) -> Vec<u8> {
    let mut out = vec![0x80, 204, 0, 3];
    out.extend(sender.to_be_bytes());
    out.extend(5u32.to_be_bytes());
    out.extend((donl as u32).to_be_bytes());
    out
}
pub fn report(
    sender: u32,
    sequences: &[(u32, u32)],
    sr: &HashMap<u32, (u32, Instant)>,
    include_sr: bool,
) -> Vec<u8> {
    let mut out = Vec::new();
    if include_sr {
        let time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        out.extend([0x80, 200, 0, 6]);
        out.extend(sender.to_be_bytes());
        out.extend(
            (time.as_secs() as u32)
                .wrapping_add(2208988800)
                .to_be_bytes(),
        );
        out.extend(
            (((time.subsec_nanos() as u64) << 32) / 1_000_000_000).to_be_bytes()[4..].iter(),
        );
        out.extend((time.as_millis().wrapping_mul(90) as u32).to_be_bytes());
        out.extend([0; 8]);
    }
    let count = sequences.len().min(31);
    out.extend([0x80 | count as u8, 201]);
    out.extend((1 + 6 * count as u16).to_be_bytes());
    out.extend(sender.to_be_bytes());
    for &(source, sequence) in &sequences[..count] {
        out.extend(source.to_be_bytes());
        out.extend([0; 4]);
        out.extend(sequence.to_be_bytes());
        out.extend([0; 4]);
        let (lsr, delay) = sr
            .get(&source)
            .map(|(n, at)| {
                (
                    *n,
                    (at.elapsed().as_secs_f64() * 65536.0).min(u32::MAX as f64) as u32,
                )
            })
            .unwrap_or((0, 0));
        out.extend(lsr.to_be_bytes());
        out.extend(delay.to_be_bytes());
    }
    out
}
pub fn received_reports(mut data: &[u8], reports: &mut HashMap<u32, (u32, Instant)>) {
    while data.len() >= 4 {
        if data[0] >> 6 != 2 {
            return;
        }
        let size = (u16::from_be_bytes([data[2], data[3]]) as usize + 1) * 4;
        if size > data.len() {
            return;
        }
        if data[1] == 200 && size >= 28 {
            let source = u32::from_be_bytes(data[4..8].try_into().unwrap());
            let sec = u32::from_be_bytes(data[8..12].try_into().unwrap());
            let frac = u32::from_be_bytes(data[12..16].try_into().unwrap());
            if reports.len() < 64 || reports.contains_key(&source) {
                reports.insert(source, ((sec << 16) | (frac >> 16), Instant::now()));
            }
        }
        data = &data[size..];
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compound_lengths() {
        for bytes in [
            fir(1, 2, 3),
            nack(1, 2, &[65535, 0, 2, 30]),
            report(1, &[(2, 5)], &HashMap::new(), true),
        ] {
            let mut data = bytes.as_slice();
            while !data.is_empty() {
                let n = (u16::from_be_bytes([data[2], data[3]]) as usize + 1) * 4;
                assert!(n <= data.len());
                data = &data[n..];
            }
        }
    }
}
