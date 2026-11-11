//! Reliable bounded control/terminal traffic and independently coalesced decoded tiles.
use serde_json::Value;
use std::sync::Arc;
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Condvar, Mutex},
    time::Duration,
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

pub struct Packet {
    pub header: Value,
    pub payload: Vec<u8>,
}
impl Packet {
    pub fn encode(mut self) -> Vec<u8> {
        self.header["payloadLength"] = self.payload.len().into();
        let header = serde_json::to_vec(&self.header).expect("JSON value");
        let mut result = Vec::with_capacity(4 + header.len() + self.payload.len());
        result.extend((header.len() as u32).to_be_bytes());
        result.extend(header);
        result.append(&mut self.payload);
        result
    }
}
#[derive(Default)]
struct Pending {
    controls: VecDeque<(Packet, OwnedSemaphorePermit)>,
    pictures: BTreeMap<(u64, u64), Packet>,
    picture_bytes: usize,
    closed: bool,
}
pub struct Events {
    pending: Mutex<Pending>,
    wake: Condvar,
    slots: Arc<Semaphore>,
}
impl Events {
    pub fn new() -> Self {
        Self {
            pending: Mutex::default(),
            wake: Condvar::new(),
            slots: Arc::new(Semaphore::new(128)),
        }
    }
    pub async fn push(&self, packet: Packet) {
        let kind = packet.header["kind"].as_str().unwrap_or("");
        if kind == "frame" {
            // Only decoded frames enter this queue. Never discard codec reference packets.
            let key = (
                packet.header["session"].as_u64().unwrap_or(0),
                packet.header["tile"].as_u64().unwrap_or(0),
            );
            let mut q = self.pending.lock().unwrap();
            if q.closed {
                return;
            }
            if let Some(old) = q.pictures.remove(&key) {
                q.picture_bytes -= old.payload.len();
            }
            if q.picture_bytes + packet.payload.len() <= 128 * 1024 * 1024 {
                q.picture_bytes += packet.payload.len();
                q.pictures.insert(key, packet);
            }
            self.wake.notify_one();
            return;
        }
        let permit = if kind == "audio" {
            // Audio can expire, but terminal bytes and transfer completions cannot.
            match self.slots.clone().try_acquire_owned() {
                Ok(p) => p,
                Err(_) => return,
            }
        } else {
            match self.slots.clone().acquire_owned().await {
                Ok(p) => p,
                Err(_) => return,
            }
        };
        let mut q = self.pending.lock().unwrap();
        if !q.closed {
            q.controls.push_back((packet, permit));
            self.wake.notify_one();
        }
    }
    pub fn poll(&self, timeout: Duration) -> Option<Packet> {
        let q = self.pending.lock().unwrap();
        let (mut q, _) = self
            .wake
            .wait_timeout_while(q, timeout, |q| {
                !q.closed && q.controls.is_empty() && q.pictures.is_empty()
            })
            .unwrap();
        if let Some((p, _permit)) = q.controls.pop_front() {
            return Some(p);
        }
        let (_, packet) = q.pictures.pop_first()?;
        q.picture_bytes -= packet.payload.len();
        Some(packet)
    }
    pub fn close(&self) {
        self.slots.close();
        let mut q = self.pending.lock().unwrap();
        q.closed = true;
        q.controls.clear();
        q.pictures.clear();
        q.picture_bytes = 0;
        self.wake.notify_all();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[tokio::test]
    async fn latest_per_tile_preserves_other_tiles_and_control() {
        let queue = Events::new();
        for (tile, byte) in [(1, 2), (0, 4), (1, 5)] {
            queue
                .push(Packet {
                    header: json!({"session":1,"kind":"frame","tile":tile}),
                    payload: vec![byte],
                })
                .await;
        }
        queue
            .push(Packet {
                header: json!({"type":"completed"}),
                payload: vec![],
            })
            .await;
        assert_eq!(
            queue.poll(Duration::ZERO).unwrap().header["type"],
            "completed"
        );
        assert_eq!(queue.poll(Duration::ZERO).unwrap().payload, [4]);
        assert_eq!(queue.poll(Duration::ZERO).unwrap().payload, [5]);
        assert!(queue.poll(Duration::ZERO).is_none());
    }
    #[test]
    fn binary_frame_roundtrips() {
        let data = Packet {
            header: serde_json::json!({"kind":"audio"}),
            payload: vec![0, 255, 1],
        }
        .encode();
        let n = u32::from_be_bytes(data[..4].try_into().unwrap()) as usize;
        let h: Value = serde_json::from_slice(&data[4..4 + n]).unwrap();
        assert_eq!(h["payloadLength"], 3);
        assert_eq!(&data[4 + n..], &[0, 255, 1]);
    }
}
