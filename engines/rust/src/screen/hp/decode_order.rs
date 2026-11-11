//! DONL is global across Apple's tile streams. Network arrival order is not
//! decode order, including after startup. Bound repairs so a lost tile cannot
//! hold the entire display forever.
use std::time::{Duration, Instant};

pub(super) const REPAIR_WINDOW: Duration = Duration::from_millis(160);
const REORDER_WINDOW: Duration = Duration::from_millis(20);

#[derive(Default)]
pub(super) struct DecodeOrder {
    next: Option<u16>,
    gap_since: Option<Instant>,
}
impl DecodeOrder {
    pub fn is_late(&self, number: u16) -> bool {
        self.next
            .is_some_and(|next| number.wrapping_sub(next) >= 32768)
    }

    // The caller supplies the pending DONLs, already startup-sorted if next is
    // unset. Returns the queue index and number of missing pictures skipped.
    pub fn take(
        &mut self,
        numbers: impl Iterator<Item = u16>,
        now: Instant,
    ) -> Option<(usize, u16)> {
        let mut numbers = numbers.enumerate();
        let first = numbers.next()?;
        let next = self.next.unwrap_or(first.1);
        let (index, number, distance) = std::iter::once(first)
            .chain(numbers)
            .map(|(i, n)| (i, n, n.wrapping_sub(next)))
            .filter(|(_, _, d)| *d < 32768)
            .min_by_key(|(_, _, d)| *d)?;
        if distance != 0 && now.duration_since(*self.gap_since.get_or_insert(now)) < REORDER_WINDOW
        {
            return None;
        }
        self.next = Some(number.wrapping_add(1));
        self.gap_since = None;
        Some((index, distance))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn restores_tile_order_after_startup_without_delaying_ordered_frames() {
        let mut order = DecodeOrder::default();
        let now = Instant::now();
        assert_eq!(order.take([100].into_iter(), now), Some((0, 0)));
        assert_eq!(order.take([103, 102].into_iter(), now), None);
        assert_eq!(order.take([103, 102, 101].into_iter(), now), Some((2, 0)));
        assert_eq!(order.take([103, 102].into_iter(), now), Some((1, 0)));
        assert_eq!(order.take([103].into_iter(), now), Some((0, 0)));
        assert!(order.is_late(102));
    }
    #[test]
    fn bounds_loss_wait_and_rejects_retransmission_after_skip() {
        let mut order = DecodeOrder::default();
        let now = Instant::now();
        assert_eq!(order.take([10].into_iter(), now), Some((0, 0)));
        assert_eq!(order.take([13].into_iter(), now), None);
        assert_eq!(
            order.take([13, 12].into_iter(), now + REORDER_WINDOW),
            Some((1, 1))
        );
        assert_eq!(
            order.take([13].into_iter(), now + REORDER_WINDOW),
            Some((0, 0))
        );
        assert!(order.is_late(11));
    }
    #[test]
    fn orders_across_donl_wrap() {
        let mut order = DecodeOrder::default();
        let now = Instant::now();
        assert_eq!(order.take([65534].into_iter(), now), Some((0, 0)));
        assert_eq!(order.take([0].into_iter(), now), None);
        assert_eq!(order.take([0, 65535].into_iter(), now), Some((1, 0)));
        assert_eq!(order.take([0].into_iter(), now), Some((0, 0)));
        assert!(order.is_late(65535));
    }
}
