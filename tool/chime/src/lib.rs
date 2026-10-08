//! Loaf Chat's message chime: two soft sine bells a fifth apart, the same
//! on every platform. `main` writes it where the app and the iOS
//! notification extension find it.

use std::f64::consts::TAU;

pub const SAMPLE_RATE: u32 = 48_000;
pub const LENGTH_S: f64 = 0.9;
/// Full scale × this is the loudest sample: a chime, not an alarm.
pub const PEAK: f64 = 0.35;

struct Note {
    hz: f64,
    start_s: f64,
    decay_s: f64,
}

const NOTES: [Note; 2] = [
    Note { hz: 880.0, start_s: 0.0, decay_s: 0.16 },
    Note { hz: 1318.51, start_s: 0.11, decay_s: 0.26 },
];
const ATTACK_S: f64 = 0.006;
const OVERTONE: f64 = 0.18;
const FADE_S: f64 = 0.03;

/// The chime as 16-bit samples, peak-normalised to [PEAK].
pub fn samples() -> Vec<i16> {
    let n = (SAMPLE_RATE as f64 * LENGTH_S) as usize;
    let raw: Vec<f64> = (0..n)
        .map(|i| {
            let t = i as f64 / SAMPLE_RATE as f64;
            let mut v = 0.0;
            for note in &NOTES {
                let local = t - note.start_s;
                if local < 0.0 {
                    continue;
                }
                // A short ramp in, so the note starts without a click.
                let attack = (local / ATTACK_S).min(1.0);
                let env = attack * (-local / note.decay_s).exp();
                v += env
                    * ((TAU * note.hz * local).sin()
                        + OVERTONE * (TAU * 2.0 * note.hz * local).sin());
            }
            // The tail fades to exact silence, so nothing pops at the end.
            let left = LENGTH_S - t - 1.0 / SAMPLE_RATE as f64;
            v * (left / FADE_S).clamp(0.0, 1.0)
        })
        .collect();
    let loudest = raw.iter().fold(0.0_f64, |m, v| m.max(v.abs()));
    let scale = if loudest > 0.0 { PEAK * i16::MAX as f64 / loudest } else { 0.0 };
    raw.iter().map(|v| (v * scale).round() as i16).collect()
}

/// A canonical 44-byte-header PCM WAV, mono 16-bit.
pub fn wav(samples: &[i16]) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    out.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes()); // bytes a second
    out.extend_from_slice(&2u16.to_le_bytes()); // bytes a frame
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

/// A Core Audio Format file of the same samples: what an iOS notification
/// sound must be. Chunk headers are big-endian; the samples stay
/// little-endian, as the format flags say.
pub fn caf(samples: &[i16]) -> Vec<u8> {
    const LITTLE_ENDIAN_INTS: u32 = 2; // kCAFLinearPCMFormatFlagIsLittleEndian
    let mut out = Vec::new();
    out.extend_from_slice(b"caff");
    out.extend_from_slice(&1u16.to_be_bytes()); // version
    out.extend_from_slice(&0u16.to_be_bytes()); // flags
    out.extend_from_slice(b"desc");
    out.extend_from_slice(&32i64.to_be_bytes());
    out.extend_from_slice(&(SAMPLE_RATE as f64).to_be_bytes());
    out.extend_from_slice(b"lpcm");
    out.extend_from_slice(&LITTLE_ENDIAN_INTS.to_be_bytes());
    out.extend_from_slice(&2u32.to_be_bytes()); // bytes a packet
    out.extend_from_slice(&1u32.to_be_bytes()); // frames a packet
    out.extend_from_slice(&1u32.to_be_bytes()); // channels
    out.extend_from_slice(&16u32.to_be_bytes()); // bits a channel
    out.extend_from_slice(b"data");
    out.extend_from_slice(&((4 + samples.len() * 2) as i64).to_be_bytes());
    out.extend_from_slice(&0u32.to_be_bytes()); // edit count
    for s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_are_the_promised_length_and_level() {
        let s = samples();
        assert_eq!(s.len(), (SAMPLE_RATE as f64 * LENGTH_S) as usize);
        let peak = s.iter().map(|v| v.unsigned_abs()).max().unwrap_or(0);
        let target = (PEAK * i16::MAX as f64) as u16;
        assert!(peak <= target && peak + 2 >= target, "peak {peak} vs {target}");
    }

    #[test]
    fn it_starts_and_ends_silent() {
        let s = samples();
        assert_eq!(s[0], 0);
        assert_eq!(*s.last().unwrap(), 0);
    }

    #[test]
    fn the_second_note_comes_in_after_the_first() {
        let s = samples();
        let at = |t: f64| (t * SAMPLE_RATE as f64) as usize;
        // Before the second note there is energy from the first alone.
        let before: i64 = s[at(0.02)..at(0.10)].iter().map(|v| (*v as i64).abs()).sum();
        assert!(before > 0);
        // Just after the second note starts, the signal swells again.
        let decayed: i64 = s[at(0.09)..at(0.105)].iter().map(|v| (*v as i64).abs()).sum();
        let swell: i64 = s[at(0.125)..at(0.14)].iter().map(|v| (*v as i64).abs()).sum();
        assert!(swell > decayed);
    }

    #[test]
    fn wav_has_a_canonical_header() {
        let s = samples();
        let w = wav(&s);
        assert_eq!(&w[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(w[4..8].try_into().unwrap()) as usize, w.len() - 8);
        assert_eq!(&w[8..16], b"WAVEfmt ");
        assert_eq!(u16::from_le_bytes([w[22], w[23]]), 1); // mono
        assert_eq!(u32::from_le_bytes(w[24..28].try_into().unwrap()), SAMPLE_RATE);
        assert_eq!(u16::from_le_bytes([w[34], w[35]]), 16);
        assert_eq!(&w[36..40], b"data");
        assert_eq!(u32::from_le_bytes(w[40..44].try_into().unwrap()) as usize, s.len() * 2);
        assert_eq!(w.len(), 44 + s.len() * 2);
    }

    #[test]
    fn caf_carries_the_same_samples() {
        let s = samples();
        let c = caf(&s);
        assert_eq!(&c[0..4], b"caff");
        assert_eq!(u16::from_be_bytes([c[4], c[5]]), 1);
        assert_eq!(&c[8..12], b"desc");
        assert_eq!(i64::from_be_bytes(c[12..20].try_into().unwrap()), 32);
        assert_eq!(f64::from_be_bytes(c[20..28].try_into().unwrap()), SAMPLE_RATE as f64);
        assert_eq!(&c[28..32], b"lpcm");
        assert_eq!(&c[52..56], b"data");
        assert_eq!(i64::from_be_bytes(c[56..64].try_into().unwrap()) as usize, 4 + s.len() * 2);
        // The edit count, then the same little-endian samples as the WAV.
        assert_eq!(&c[64..68], &[0, 0, 0, 0]);
        assert_eq!(&c[68..], &wav(&s)[44..]);
    }

    #[test]
    fn output_is_deterministic() {
        assert_eq!(wav(&samples()), wav(&samples()));
    }
}
