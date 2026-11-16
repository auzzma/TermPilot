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
    dirty: [bool; 16],
    inflated: Vec<u8>,
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
            dirty: [true; 16],
            inflated: Vec::new(),
        })
    }
    /// Resize pixels without resetting the connection-wide compression state.
    pub fn resize(&mut self, width: usize, height: usize) -> Result<()> {
        let mut next = Self::new(width, height)?;
        // Zlib dictionaries belong to the connection, not to a desktop layout.
        std::mem::swap(&mut next.inflate, &mut self.inflate);
        std::mem::swap(&mut next.inflated, &mut self.inflated);
        *self = next;
        Ok(())
    }
    /// Fixed independent bands can be coalesced without losing earlier edits.
    pub fn band_rows(&self) -> usize { self.height.div_ceil(16).max(64) }
    fn mark(&mut self, y: usize, h: usize) {
        let rows = self.band_rows();
        for tile in y / rows..=(y + h - 1) / rows { self.dirty[tile] = true; }
    }
    pub fn take_bands(&mut self) -> Vec<(usize, usize, usize, Vec<u8>)> {
        let rows = self.band_rows();
        let mut bands = Vec::new();
        for tile in 0..self.height.div_ceil(rows) {
            if !std::mem::replace(&mut self.dirty[tile], false) { continue; }
            let y = tile * rows;
            let h = rows.min(self.height - y);
            bands.push((tile, y, h, self.pixels[y*self.width*4..(y+h)*self.width*4].to_vec()));
        }
        bands
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
        let mut changed = false;
        for row in 0..h {
            let target = ((y + row) * self.width + x) * 4;
            changed |= self.pixels[target..target + w * 4] != data[row * w * 4..(row + 1) * w * 4];
            self.pixels[target..target + w * 4]
                .copy_from_slice(&data[row * w * 4..(row + 1) * w * 4]);
        }
        if changed { self.mark(y, h); }
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
        if x == sx && y == sy { return Ok(()); }
        // memmove within each row; reverse row order for downward overlapping copies.
        for i in 0..h {
            let row = if y > sy { h - 1 - i } else { i };
            let source = ((sy + row) * self.width + sx) * 4;
            let target = ((y + row) * self.width + x) * 4;
            self.pixels.copy_within(source..source + w * 4, target);
        }
        self.mark(y, h);
        Ok(())
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
        let mut data = std::mem::take(&mut self.inflated);
        data.resize(w * h * 4 + 1, 0);
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
        self.raw(x, y, w, h, &data[..written])?;
        self.inflated = data;
        Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn desktop_resize_preserves_the_connections_zlib_dictionary() {
        let mut compressor=flate2::Compress::new(flate2::Compression::default(),true);
        let mut frame=Frame::new(2,2).unwrap();
        for (w,h,value) in [(2,2,42),(3,65,43)] {
            let pixels=vec![value;w*h*4];let mut compressed=Vec::with_capacity(pixels.len()+64);
            compressor.compress_vec(&pixels,&mut compressed,flate2::FlushCompress::Sync).unwrap();
            frame.resize(w,h).unwrap();frame.zlib(0,0,w,h,&compressed).unwrap();
            assert_eq!(frame.pixels,pixels);
        }
    }
    #[test]
    fn partial_changes_send_independent_bands_and_cover_the_bottom_edge() {
        let mut frame = Frame::new(1920, 1080).unwrap();
        let full = frame.take_bands();
        assert_eq!(full.len(), 16);
        assert_eq!(full.iter().map(|b| b.3.len()).sum::<usize>(), 1920*1080*4);
        assert_eq!((full[15].1, full[15].2), (1020, 60));
        frame.raw(17, 300, 8, 8, &vec![11; 8*8*4]).unwrap();
        frame.raw(25, 301, 8, 8, &vec![22; 8*8*4]).unwrap();
        let bands = frame.take_bands();
        assert_eq!(bands.len(), 1);
        let (tile, y, h, ref data) = bands[0];
        assert_eq!(tile, 4);
        assert_eq!(data, &frame.pixels[y*1920*4..(y+h)*1920*4]);
        assert!(data.len()*15 < 1920*1080*4);
        assert!(frame.take_bands().is_empty());
        frame.raw(25, 301, 8, 8, &vec![22; 8*8*4]).unwrap();
        assert!(frame.take_bands().is_empty());
    }
    #[test]
    fn overlapping_scroll_copies_match_an_independent_snapshot() {
        for (x, y, sx, sy) in [(1,2,0,0), (0,0,1,2), (1,0,0,0), (0,0,1,0)] {
            let mut frame = Frame::new(7, 140).unwrap();
            for (i, byte) in frame.pixels.iter_mut().enumerate() { *byte = (i%251) as u8; }
            let before = frame.pixels.clone();
            frame.take_bands();
            frame.copy(x,y,5,130,sx,sy).unwrap();
            for row in 0..130 {
                assert_eq!(&frame.pixels[((y+row)*7+x)*4..((y+row)*7+x+5)*4],
                    &before[((sy+row)*7+sx)*4..((sy+row)*7+sx+5)*4]);
            }
            assert_eq!(frame.take_bands().len(), 3);
        }
    }
    #[test]
    fn small_legacy_fixture_remains_one_complete_frame() {
        let mut frame = Frame::new(2,2).unwrap();
        assert_eq!(frame.take_bands(), vec![(0,0,2,vec![0;16])]);
    }
}
