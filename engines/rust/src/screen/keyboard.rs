use std::time::Duration;
use tokio::time::{sleep_until, Instant};

/// Apple screen sharing can drop synthetic down/up events delivered together.
/// Keep transitions apart at the socket writer, where IPC buffering cannot undo
/// the spacing. Physical typing already exceeds this interval in most cases.
pub(super) struct KeyPacer {
    enabled: bool,
    sent: Option<Instant>,
}

impl KeyPacer {
    const INTERVAL: Duration = Duration::from_millis(20);

    pub fn new(enabled: bool) -> Self {
        Self {
            enabled,
            sent: None,
        }
    }

    pub async fn before_send(&self) {
        if self.enabled {
            if let Some(sent) = self.sent {
                sleep_until(sent + Self::INTERVAL).await;
            }
        }
    }

    pub fn after_send(&mut self) {
        self.sent = Some(Instant::now());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn apple_transitions_are_spaced_from_completed_write() {
        let mut pacer = KeyPacer::new(true);
        pacer.before_send().await;
        // A slow socket write must not consume the next transition's delay.
        tokio::time::sleep(KeyPacer::INTERVAL).await;
        pacer.after_send();
        let sent = pacer.sent.unwrap();
        pacer.before_send().await;
        assert!(sent.elapsed() >= KeyPacer::INTERVAL);
        pacer.after_send();
        let released = pacer.sent.unwrap();
        pacer.before_send().await;
        assert!(released.elapsed() >= KeyPacer::INTERVAL);
    }

    #[tokio::test]
    async fn ordinary_vnc_does_not_wait_for_apple_timing() {
        let mut pacer = KeyPacer::new(false);
        pacer.after_send();
        tokio::time::timeout(Duration::from_millis(5), pacer.before_send())
            .await
            .expect("Non-Apple VNC keys should be immediately ready");
    }
}
