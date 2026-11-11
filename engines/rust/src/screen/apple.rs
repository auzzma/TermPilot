//! Apple's SRP dialect, ported from engines/screen-sharing/iShareScreen
//! (AGPL-3.0-or-later) for the native connection engine. Secret exponentiation uses fixed-width
//! crypto-bigint operations.
use anyhow::{ensure, Context, Result};
use crypto_bigint::{
    modular::{FixedMontyForm, FixedMontyParams},
    Odd, U4096,
};
use rand::{rngs::OsRng, RngCore};
use rsa::{pkcs8::DecodePublicKey, Pkcs1v15Encrypt, RsaPublicKey};
use sha2::{Digest, Sha256, Sha512};
use subtle::ConstantTimeEq;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

fn hash(parts: &[&[u8]]) -> Vec<u8> {
    let mut h = Sha512::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().to_vec()
}
fn big(b: &[u8]) -> Result<U4096> {
    ensure!(b.len() <= 512, "SRP integer size");
    let mut out = [0; 512];
    out[512 - b.len()..].copy_from_slice(b);
    Ok(U4096::from_be_slice(&out))
}
pub struct Challenge {
    pub modulus: Vec<u8>,
    pub generator: u32,
    pub salt: Vec<u8>,
    pub public: Vec<u8>,
    pub iterations: u32,
    pub cap: Vec<u8>,
}
pub struct Proof {
    pub a: Vec<u8>,
    pub m1: Vec<u8>,
    pub key: Vec<u8>,
}
impl Drop for Proof {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.a.zeroize();
        self.m1.zeroize();
        self.key.zeroize();
    }
}
pub fn solve(c: &Challenge, password: &str, entropy: &[u8]) -> Result<Proof> {
    // Pin the safe group from RFC 5054 Appendix A, group 5:
    // https://www.rfc-editor.org/rfc/rfc5054.html#appendix-A
    ensure!(
        hex::encode(Sha256::digest(&c.modulus))
            == "4ee95187682bcb230ad26a95205f6920e84708f6251b3894329b09ec23919e33",
        "Unrecognized SRP group"
    );
    let n = big(&c.modulus)?;
    let g = U4096::from(c.generator);
    let b = big(&c.public)?;
    ensure!(
        c.modulus.len() == 512
            && c.modulus[0] & 0x80 != 0
            && c.generator == 5
            && c.public.len() == 512
            && b != U4096::ZERO
            && b < n,
        "invalid SRP group/public"
    );
    ensure!(entropy.len() == 64, "SRP entropy length");
    // Only the public server modulus is processed by a variable-time operation.
    let odd = Option::<Odd<U4096>>::from(Odd::new(n)).context("even SRP modulus")?;
    let params = FixedMontyParams::new_vartime(odd);
    let gm = FixedMontyForm::new(&g, &params);
    ensure!(
        (1..=1_000_000).contains(&c.iterations),
        "SRP iteration limit"
    );
    let gp = g.to_be_bytes();
    let k = big(&hash(&[&c.modulus, &gp]))?;
    // 512-bit entropy + 1 is always below the validated 4096-bit modulus.
    let a = big(entropy)?.wrapping_add(&U4096::ONE);
    let ap = gm
        .pow_bounded_exp(&a, 513)
        .retrieve()
        .to_be_bytes()
        .to_vec();
    let u = big(&hash(&[&ap, &c.public]))?;
    ensure!(u != U4096::ZERO, "invalid SRP scrambling");
    let mut dk = zeroize::Zeroizing::new([0u8; 128]);
    pbkdf2::pbkdf2_hmac::<Sha512>(password.as_bytes(), &c.salt, c.iterations, &mut *dk);
    let inner = hash(&[b":", &*dk]);
    let x = big(&hash(&[&c.salt, &inner]))?;
    let base = FixedMontyForm::new(&b, &params)
        - FixedMontyForm::new(&k, &params) * gm.pow_bounded_exp(&x, 512);
    let exponent = a.wrapping_add(&u.wrapping_mul(&x));
    // Public, fixed upper bounds: a <= 513 bits; u*x+a <= 1025 bits.
    let shared = base.pow_bounded_exp(&exponent, 1025).retrieve();
    let key = hash(&[&shared.to_be_bytes()]);
    let xor: Vec<u8> = hash(&[&c.modulus])
        .iter()
        .zip(hash(&[&gp]))
        .map(|(a, b)| a ^ b)
        .collect();
    let m1 = hash(&[&xor, &hash(&[b""]), &c.salt, &ap, &c.public, &key]);
    Ok(Proof { a: ap, m1, key })
}
pub fn verify_result(packet: &[u8], status: u32, p: &Proof) -> Result<()> {
    ensure!(status == 0, "authenticationRejected");
    ensure!(packet.len() == 98, "SRP envelope");
    ensure!(
        packet[..10] == [0, 0, 0, 2, 0, 92, 0, 0, 0, 88],
        "SRP envelope"
    );
    let b = &packet[10..];
    ensure!(
        b[0] == 64 && b[65] == 16 && b[82..] == [0; 6],
        "SRP result fields"
    );
    let expected = hash(&[&p.a, &p.m1, &p.key]);
    ensure!(
        bool::from(expected.ct_eq(&b[1..65])),
        "serverProof"
    );
    Ok(())
}
fn take<'a>(buf: &mut &'a [u8], n: usize) -> Result<&'a [u8]> {
    ensure!(buf.len() >= n, "truncated SRP field");
    let (a, b) = buf.split_at(n);
    *buf = b;
    Ok(a)
}
fn u16be(buf: &mut &[u8]) -> Result<usize> {
    Ok(u16::from_be_bytes(take(buf, 2)?.try_into()?) as usize)
}
pub fn parse(data: &[u8]) -> Result<Challenge> {
    let mut b = data;
    take(&mut b, 12)?;
    ensure!(take(&mut b, 1)? == [0], "SRP DER marker");
    let modulus = take(&mut b, 512)?.to_vec();
    let n = u16be(&mut b)?;
    ensure!(n == 1, "SRP generator length");
    let generator = take(&mut b, n)?[0] as u32;
    let n = take(&mut b, 1)?[0] as usize;
    let salt = take(&mut b, n)?.to_vec();
    let n = u16be(&mut b)?;
    ensure!(n == 512, "SRP public length");
    let public = take(&mut b, n)?.to_vec();
    let iterations = u64::from_be_bytes(take(&mut b, 8)?.try_into()?);
    ensure!((1..=1_000_000).contains(&iterations), "SRP iterations");
    let n = u16be(&mut b)?;
    let cap = take(&mut b, n)?.to_vec();
    Ok(Challenge {
        modulus,
        generator,
        salt,
        public,
        iterations: iterations as u32,
        cap,
    })
}
async fn packet(stream: &mut (impl AsyncRead + Unpin)) -> Result<Vec<u8>> {
    let mut n = [0; 4];
    stream.read_exact(&mut n).await?;
    let n = u32::from_be_bytes(n) as usize;
    ensure!(n <= 16384, "SRP packet limit");
    let mut b = vec![0; n];
    stream.read_exact(&mut b).await?;
    Ok(b)
}
async fn send(stream: &mut (impl AsyncWrite + Unpin), data: &[u8]) -> Result<()> {
    stream.write_all(&(data.len() as u32).to_be_bytes()).await?;
    stream.write_all(data).await?;
    Ok(())
}
pub async fn authenticate(
    stream: &mut (impl AsyncRead + AsyncWrite + Unpin),
    username: &str,
    password: &str,
) -> Result<[u8; 16]> {
    stream
        .write_all(b"\x21\x00\x00\x00\x0a\x01\x00RSA1\x00\x00\x00\x00")
        .await?;
    let response = packet(stream).await?;
    let mut b = response.as_slice();
    take(&mut b, 2)?;
    let n = u32::from_be_bytes(take(&mut b, 4)?.try_into()?) as usize;
    let key = RsaPublicKey::from_public_key_der(take(&mut b, n)?).context("Apple RSA envelope")?;
    let mut inner = (username.len() as u32).to_be_bytes().to_vec();
    inner.extend(username.as_bytes());
    inner.extend([0; 3]);
    let mut payload = (inner.len() as u32).to_be_bytes().to_vec();
    payload.extend(inner);
    let encrypted = key.encrypt(&mut OsRng, Pkcs1v15Encrypt, &payload)?;
    ensure!(encrypted.len() == 256, "Apple RSA key length");
    let mut message = b"\x01\x00RSA1\x00\x02\x01\x00".to_vec();
    message.extend(encrypted);
    message.extend([0; 384]);
    send(stream, &message).await?;
    let challenge = parse(&packet(stream).await?)?;
    let mut entropy = [0; 64];
    OsRng.fill_bytes(&mut entropy);
    let password = zeroize::Zeroizing::new(password.to_string());
    let (challenge, p) = tokio::task::spawn_blocking(move || {
        let p = solve(&challenge, &password, &entropy)?;
        Ok::<_, anyhow::Error>((challenge, p))
    })
    .await??;
    let mut sd = 512u16.to_be_bytes().to_vec();
    sd.extend(&p.a);
    sd.push(64);
    sd.extend(&p.m1);
    sd.extend((challenge.cap.len() as u16).to_be_bytes());
    sd.extend(&challenge.cap);
    sd.push(16);
    let mut iv = [0; 16];
    OsRng.fill_bytes(&mut iv);
    sd.extend(iv);
    let mut proof = b"\x01\x00RSA1\x00\x02".to_vec();
    proof.extend(((sd.len() + 4) as u16).to_be_bytes());
    proof.extend((sd.len() as u32).to_be_bytes());
    proof.extend(sd);
    ensure!(proof.len() <= 1076, "proof overflow");
    proof.resize(1076, 0);
    send(stream, &proof).await?;
    let reply = packet(stream).await?;
    let mut result = [0; 4];
    stream.read_exact(&mut result).await?;
    verify_result(&reply, u32::from_be_bytes(result), &p)?;
    Ok(Sha256::digest(&p.key)[..16].try_into()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn truncated_challenges_are_rejected_without_panics() {
        for n in 0..1100 {
            assert!(parse(&vec![0; n]).is_err());
        }
    }
    #[test]
    fn forged_server_proof_is_rejected() {
        let p = Proof {
            a: vec![1; 512],
            m1: vec![2; 64],
            key: vec![3; 64],
        };
        let mut packet = vec![0, 0, 0, 2, 0, 92, 0, 0, 0, 88, 64];
        packet.extend(hash(&[&p.a, &p.m1, &p.key]));
        packet.push(16);
        packet.extend([0; 22]);
        assert!(verify_result(&packet, 0, &p).is_ok());
        packet[30] ^= 1;
        assert_eq!(verify_result(&packet, 0, &p).unwrap_err().to_string(), "serverProof");
        assert_eq!(verify_result(&[], 1, &p).unwrap_err().to_string(), "authenticationRejected");
        assert_eq!(verify_result(&[], 0, &p).unwrap_err().to_string(), "SRP envelope");
    }
}
