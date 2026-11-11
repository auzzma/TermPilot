//! A quiet desktop is normal. Only authenticated session/layout transitions
//! arm media recovery; heartbeat, pointer and clipboard traffic never do.
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Transition {
    Layout,
    Session,
}
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Action {
    Restart(u8),
    Recovered,
    Failed,
}
struct Pending {
    started: Instant,
    changed: Instant,
    session: bool,
    attempts: u8,
    attempted: Option<Instant>,
    frames: u64,
}
#[derive(Default)]
pub(super) struct Recovery {
    pending: Option<Pending>,
    last_transition: Option<Instant>,
}
impl Recovery {
    pub fn restarted(&mut self, frames: u64) {
        if let Some(p) = &mut self.pending {
            p.frames = frames;
        }
    }
    pub fn transition(&mut self, kind: Transition, now: Instant, frames: u64) {
        self.last_transition = Some(now);
        if let Some(p) = &mut self.pending {
            // Offer replies contain layout records too. They must not reset
            // the retry budget or indefinitely postpone a pending attempt.
            if p.attempts == 0 {
                p.changed = now;
                p.session |= kind == Transition::Session;
            }
        } else {
            self.pending = Some(Pending {
                started: now,
                changed: now,
                session: kind == Transition::Session,
                attempts: 0,
                attempted: None,
                frames,
            });
        }
    }
    pub fn interrupted(&self, error: &anyhow::Error, now: Instant) -> bool {
        if !self
            .last_transition
            .is_some_and(|at| now.duration_since(at) < Duration::from_secs(30))
        {
            return false;
        }
        // Some macOS revisions tear down the control socket during the agent
        // handoff, even after a media re-offer succeeded. Retry via the client's
        // normal credential path, without retrying authentication/proof errors.
        error.downcast_ref::<std::io::Error>().is_some_and(|io| {
            matches!(
                io.kind(),
                std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::UnexpectedEof
                    | std::io::ErrorKind::NotConnected
                    | std::io::ErrorKind::TimedOut
            )
        }) || matches!(
            error.to_string().as_str(),
            "Remote screen connection closed"
                | "disconnected"
                | "connectionTimeout"
                | "Partial control record timed out"
        )
    }
    pub fn poll(&mut self, now: Instant, frames: u64, last_frame: Instant) -> Option<Action> {
        let p = self.pending.as_mut()?;
        if let Some(at) = p.attempted {
            if frames > p.frames && now.duration_since(at) >= Duration::from_millis(500) {
                self.pending = None;
                return Some(Action::Recovered);
            }
            if now.duration_since(at) < Duration::from_secs(5) {
                return None;
            }
            if p.attempts == 3 {
                self.pending = None;
                return Some(Action::Failed);
            }
        } else {
            let age = now.duration_since(p.started);
            if age < Duration::from_secs(1)
                || (now.duration_since(p.changed) < Duration::from_secs(1)
                    && age < Duration::from_secs(3))
            {
                return None;
            }
            // Layout-only notifications need evidence of stalled output.
            if !p.session && now.duration_since(last_frame) < Duration::from_secs(2) {
                if age >= Duration::from_secs(10) {
                    self.pending = None;
                }
                return None;
            }
        }
        p.attempts += 1;
        p.attempted = Some(now);
        p.frames = frames;
        Some(Action::Restart(p.attempts))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn transport_reset_during_handoff_recovers_but_authentication_and_unrelated_failures_do_not() {
        let now = Instant::now();
        let mut r = Recovery::default();
        let reset = anyhow::Error::new(std::io::Error::from(std::io::ErrorKind::ConnectionReset));
        assert!(!r.interrupted(&reset, now));
        r.transition(Transition::Session, now, 4);
        assert!(r.interrupted(&reset, now));
        assert!(r.interrupted(&anyhow::anyhow!("Remote screen connection closed"), now));
        for code in [
            "authenticationRejected",
            "serverProof",
            "Control authentication failed",
            "displayMode",
        ] {
            assert!(!r.interrupted(&anyhow::anyhow!(code), now));
        }
        assert!(!r.interrupted(&reset, now + Duration::from_secs(30)));
    }
    #[test]
    fn server_close_after_first_recovered_picture_still_uses_automatic_reconnect() {
        let now = Instant::now();
        let mut r = Recovery::default();
        r.transition(Transition::Session, now, 4);
        assert_eq!(
            r.poll(now + Duration::from_secs(1), 4, now),
            Some(Action::Restart(1))
        );
        assert_eq!(
            r.poll(now + Duration::from_secs(2), 5, now),
            Some(Action::Recovered)
        );
        assert!(r.interrupted(
            &anyhow::anyhow!("Remote screen connection closed"),
            now + Duration::from_secs(5)
        ));
    }
    #[test]
    fn old_in_flight_frames_cannot_complete_a_new_recovery() {
        let now = Instant::now();
        let mut r = Recovery::default();
        r.transition(Transition::Session, now, 4);
        assert_eq!(
            r.poll(now + Duration::from_secs(1), 4, now),
            Some(Action::Restart(1))
        );
        r.restarted(7);
        assert_eq!(r.poll(now + Duration::from_secs(2), 7, now), None);
        assert_eq!(
            r.poll(now + Duration::from_secs(3), 8, now),
            Some(Action::Recovered)
        );
    }
    #[test]
    fn fresh_media_keys_reject_delayed_packets_and_allow_reused_sequence_numbers() {
        use super::super::{crypto::Rtp, offers::Keys};
        let old = Keys::new();
        let new = Keys::new();
        let old_tx = Rtp::new(&*old.video_server).unwrap();
        let new_tx = Rtp::new(&*new.video_server).unwrap();
        let stale = old_tx.encrypt(42, 1, 100, &[1, 2, 3]).unwrap();
        let fresh = new_tx.encrypt(42, 1, 100, &[4, 5, 6]).unwrap();
        let mut receiver = Rtp::new(&*new.video_server).unwrap();
        assert!(receiver.decrypt(&stale).unwrap().is_none());
        assert_eq!(
            receiver.decrypt(&fresh).unwrap().unwrap().payload,
            [4, 5, 6]
        );
        assert!(receiver.decrypt(&fresh).unwrap().is_none());
    }
    #[test]
    fn quiet_desktop_never_arms_recovery() {
        let now = Instant::now();
        let mut r = Recovery::default();
        assert_eq!(r.poll(now + Duration::from_secs(600), 4, now), None);
    }
    #[test]
    fn login_restarts_even_if_the_spinner_was_still_producing_frames() {
        let now = Instant::now();
        let mut r = Recovery::default();
        r.transition(Transition::Session, now, 4);
        assert_eq!(r.poll(now, 4, now), None);
        assert_eq!(
            r.poll(now + Duration::from_secs(1), 9, now),
            Some(Action::Restart(1))
        );
        assert_eq!(
            r.poll(now + Duration::from_secs(2), 10, now),
            Some(Action::Recovered)
        );
        assert_eq!(r.poll(now + Duration::from_secs(600), 10, now), None);
    }
    #[test]
    fn duplicate_layouts_cannot_starve_or_reset_the_retry_budget() {
        let now = Instant::now();
        let mut r = Recovery::default();
        r.transition(Transition::Session, now, 4);
        for second in 1..=18 {
            let at = now + Duration::from_secs(second);
            r.transition(Transition::Layout, at, 4);
            let expected = match second {
                3 => Some(Action::Restart(1)),
                8 => Some(Action::Restart(2)),
                13 => Some(Action::Restart(3)),
                18 => Some(Action::Failed),
                _ => None,
            };
            assert_eq!(r.poll(at, 4, now), expected);
        }
    }
    #[test]
    fn healthy_layout_does_not_interrupt_video_and_a_later_unlock_can_recover() {
        let now = Instant::now();
        let mut r = Recovery::default();
        r.transition(Transition::Layout, now, 1);
        for second in 0..=12 {
            let at = now + Duration::from_secs(second);
            assert_eq!(r.poll(at, second + 1, at), None);
        }
        let at = now + Duration::from_secs(30);
        r.transition(Transition::Session, at, 20);
        assert_eq!(
            r.poll(at + Duration::from_secs(1), 20, at),
            Some(Action::Restart(1))
        );
    }
    #[test]
    fn layout_without_session_notification_recovers_stopped_video() {
        let now = Instant::now();
        let mut r = Recovery::default();
        r.transition(Transition::Layout, now, 4);
        assert_eq!(r.poll(now + Duration::from_secs(1), 4, now), None);
        assert_eq!(
            r.poll(now + Duration::from_secs(2), 4, now),
            Some(Action::Restart(1))
        );
        assert_eq!(
            r.poll(now + Duration::from_secs(3), 5, now),
            Some(Action::Recovered)
        );
        r.transition(Transition::Layout, now + Duration::from_secs(3), 5);
        // A second handoff can follow a successful first one. Do not hide its
        // layout behind a cooldown and leave the newly stalled stream stuck.
        assert_eq!(
            r.poll(now + Duration::from_secs(5), 5, now),
            Some(Action::Restart(1))
        );
    }
}
