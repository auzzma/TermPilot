//! Bounded RFB pixel reconstruction.
use anyhow::{ensure, Result};
use cipher::{BlockEncrypt, KeyInit};
use des::Des;
use flate2::{Decompress, FlushDecompress, Status};
pub struct Frame {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
    inflate: Decompress,
}
impl Frame {
    pub fn new(w: usize, h: usize) -> Result<Self> {
        ensure!(
            w > 0 && h > 0 && w <= 8192 && h <= 8192 && w * h <= 16 * 1024 * 1024,
            "frame limit"
        );
        Ok(Self {
            width: w,
            height: h,
            pixels: vec![0; w * h * 4],
            inflate: Decompress::new(true),
        })
    }
    pub fn bounds(&self, x: usize, y: usize, w: usize, h: usize) -> Result<()> {
        ensure!(
            w > 0 && h > 0 && x + w <= self.width && y + h <= self.height,
            "rectangle out of bounds"
        );
        Ok(())
    }
    pub fn raw(&mut self, x: usize, y: usize, w: usize, h: usize, data: &[u8]) -> Result<()> {
        self.bounds(x, y, w, h)?;
        ensure!(data.len() == w * h * 4, "pixel length");
        for row in 0..h {
            let target = ((y + row) * self.width + x) * 4;
            self.pixels[target..target + w * 4]
                .copy_from_slice(&data[row * w * 4..(row + 1) * w * 4]);
        }
        Ok(())
    }
    pub fn copy(
        &mut self,
        x: usize,
        y: usize,
        w: usize,
        h: usize,
        sx: usize,
        sy: usize,
    ) -> Result<()> {
        self.bounds(sx, sy, w, h)?;
        self.bounds(x, y, w, h)?;
        let data: Vec<u8> = (0..h)
            .flat_map(|row| {
                self.pixels
                    [((sy + row) * self.width + sx) * 4..((sy + row) * self.width + sx + w) * 4]
                    .iter()
                    .copied()
            })
            .collect();
        self.raw(x, y, w, h, &data)
    }
    pub fn zlib(
        &mut self,
        x: usize,
        y: usize,
        w: usize,
        h: usize,
        compressed: &[u8],
    ) -> Result<()> {
        self.bounds(x, y, w, h)?;
        let mut data = vec![0; w * h * 4 + 1];
        let before = self.inflate.total_out();
        let input = self.inflate.total_in();
        let status = self
            .inflate
            .decompress(compressed, &mut data, FlushDecompress::Sync)?;
        let written = (self.inflate.total_out() - before) as usize;
        ensure!(
            written == w * h * 4 && self.inflate.total_in() - input == compressed.len() as u64,
            "zlib size mismatch"
        );
        if status == Status::StreamEnd {
            self.inflate.reset(true);
        }
        self.raw(x, y, w, h, &data[..written])
    }
}
pub fn classic(challenge: &[u8], password: &str) -> Result<Vec<u8>> {
    ensure!(challenge.len() == 16, "challenge length");
    let mut key = [0u8; 8];
    for (i, c) in password.chars().take(8).enumerate() {
        ensure!((c as u32) < 256, "VNC Latin-1 password");
        key[i] = (c as u8).reverse_bits();
    }
    let cipher = Des::new_from_slice(&key)?;
    let mut result = challenge.to_vec();
    for block in result.chunks_exact_mut(8) {
        cipher.encrypt_block(block.into());
    }
    Ok(result)
}
