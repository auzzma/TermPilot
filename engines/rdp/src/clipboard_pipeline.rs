//! Bounded, ordered clipboard reads. No file bytes cross the UI adapter.
use super::{CHUNK, RemoteReadRejected, TransferControl};
use anyhow::{Context, Result, ensure};
use std::{collections::BTreeMap, future::Future, sync::Arc};
use tokio::{
    io::{AsyncWrite, AsyncWriteExt},
    task::JoinSet,
};

pub(super) const READ_WINDOW: usize = 8;

pub(super) async fn copy_ranges<W, F, Fut, P>(
    target: &mut W,
    size: u64,
    control: Arc<TransferControl>,
    fetch: F,
    mut progress: P,
) -> Result<()>
where
    W: AsyncWrite + Unpin,
    F: Fn(u64, u32) -> Fut + Clone + Send + Sync + 'static,
    Fut: Future<Output = Result<Vec<u8>>> + Send + 'static,
    P: FnMut(u64),
{
    let mut pending = JoinSet::new();
    let mut ready = BTreeMap::new();
    let (mut position, mut next) = (0, 0);
    let mut window = READ_WINDOW;
    while position < size {
        control.ready().await?;
        while next < size && next - position < window as u64 * CHUNK as u64 {
            let start = next;
            let length = (size - start).min(CHUNK as u64) as usize;
            let fetch = fetch.clone();
            let gate = control.clone();
            pending.spawn(async move {
                let result = async {
                    let mut data = Vec::with_capacity(length);
                    while data.len() < length {
                        gate.ready().await?;
                        let bytes = tokio::select! {
                            _ = gate.cancelled() => anyhow::bail!("File transfer cancelled"),
                            result = fetch(start + data.len() as u64, (length - data.len()) as u32) => result?,
                        };
                        ensure!(!bytes.is_empty() && bytes.len() <= length - data.len(), "Invalid remote file chunk");
                        data.extend_from_slice(&bytes);
                    }
                    Ok::<_, anyhow::Error>(data)
                }.await;
                (start, result)
            });
            next += length as u64;
        }
        let (offset, result) = tokio::select! {
            _ = control.cancelled() => anyhow::bail!("File transfer cancelled"),
            result = pending.join_next() => result.context("Missing clipboard read")??,
        };
        match result {
            Ok(bytes) => {
                ready.insert(offset, bytes);
            }
            Err(error) if window > 1 && error.is::<RemoteReadRejected>() => {
                // Probe the same unfinished data serially. Permission/read errors
                // still fail if the serial retry is rejected; never mask bad data.
                pending.abort_all();
                while pending.join_next().await.is_some() {}
                ready.clear();
                window = 1;
                next = position;
                continue;
            }
            Err(error) => return Err(error),
        }
        while let Some(bytes) = ready.remove(&position) {
            control.ready().await?;
            tokio::select! {
                _ = control.cancelled() => anyhow::bail!("File transfer cancelled"),
                result = target.write_all(&bytes) => result?,
            }
            position += bytes.len() as u64;
            progress(position);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::time::Duration;

    #[tokio::test]
    async fn disk_failure_cancels_remaining_reads_without_publishing_progress() {
        struct BrokenDisk;
        impl AsyncWrite for BrokenDisk {
            fn poll_write(
                self: std::pin::Pin<&mut Self>,
                _: &mut std::task::Context<'_>,
                _: &[u8],
            ) -> std::task::Poll<std::io::Result<usize>> {
                std::task::Poll::Ready(Err(std::io::Error::other("fixture disk full")))
            }
            fn poll_flush(
                self: std::pin::Pin<&mut Self>,
                _: &mut std::task::Context<'_>,
            ) -> std::task::Poll<std::io::Result<()>> {
                std::task::Poll::Ready(Ok(()))
            }
            fn poll_shutdown(
                self: std::pin::Pin<&mut Self>,
                _: &mut std::task::Context<'_>,
            ) -> std::task::Poll<std::io::Result<()>> {
                std::task::Poll::Ready(Ok(()))
            }
        }
        struct Active(Arc<AtomicUsize>);
        impl Drop for Active {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::SeqCst);
            }
        }
        let active = Arc::new(AtomicUsize::new(0));
        let count = active.clone();
        let result = copy_ranges(
            &mut BrokenDisk,
            CHUNK as u64 * 32,
            Arc::default(),
            move |offset, length| {
                let count = count.clone();
                async move {
                    count.fetch_add(1, Ordering::SeqCst);
                    let _active = Active(count);
                    if offset == 0 {
                        tokio::time::sleep(Duration::from_millis(10)).await;
                        Ok(vec![0; length as usize])
                    } else {
                        std::future::pending().await
                    }
                }
            },
            |_| panic!("Failed write must not advance progress"),
        )
        .await;
        assert_eq!(result.unwrap_err().to_string(), "fixture disk full");
        tokio::time::timeout(Duration::from_secs(1), async {
            while active.load(Ordering::SeqCst) != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }
    #[tokio::test]
    async fn parallel_short_reads_are_ordered_and_bounded() {
        let data = Arc::new(
            (0..CHUNK as usize * 19 + 37)
                .map(|n| (n % 251) as u8)
                .collect::<Vec<_>>(),
        );
        let live = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let fetch = {
            let data = data.clone();
            let live = live.clone();
            let peak = peak.clone();
            move |offset: u64, length: u32| {
                let data = data.clone();
                let live = live.clone();
                let peak = peak.clone();
                async move {
                    let n = live.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(n, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(
                        1 + (7 - offset / (CHUNK as u64) % 8),
                    ))
                    .await;
                    let length = (length as usize).min(65536);
                    let bytes = data[offset as usize..offset as usize + length].to_vec();
                    live.fetch_sub(1, Ordering::SeqCst);
                    Ok(bytes)
                }
            }
        };
        let mut actual = Vec::new();
        let mut previous = 0;
        copy_ranges(&mut actual, data.len() as u64, Arc::default(), fetch, |n| {
            assert!(n > previous);
            previous = n;
        })
        .await
        .unwrap();
        assert_eq!(actual, *data);
        assert_eq!(previous, data.len() as u64);
        assert!(peak.load(Ordering::SeqCst) > 1);
        assert!(peak.load(Ordering::SeqCst) <= READ_WINDOW);
    }
    #[tokio::test]
    async fn rejected_parallel_read_retries_unfinished_offset_serially() {
        let rejected = Arc::new(AtomicBool::new(false));
        let calls = Arc::new(AtomicUsize::new(0));
        let fetch = {
            let rejected = rejected.clone();
            let calls = calls.clone();
            move |offset: u64, length: u32| {
                let rejected = rejected.clone();
                let calls = calls.clone();
                async move {
                    calls.fetch_add(1, Ordering::SeqCst);
                    if offset == CHUNK as u64 && !rejected.swap(true, Ordering::SeqCst) {
                        return Err(anyhow::Error::new(RemoteReadRejected));
                    }
                    tokio::task::yield_now().await;
                    Ok((offset..offset + length as u64)
                        .map(|n| (n % 239) as u8)
                        .collect::<Vec<_>>())
                }
            }
        };
        let mut bytes = Vec::new();
        let size = CHUNK as u64 * 12;
        copy_ranges(&mut bytes, size, Arc::default(), fetch, |_| {})
            .await
            .unwrap();
        assert_eq!(
            bytes,
            (0..size).map(|n| (n % 239) as u8).collect::<Vec<_>>()
        );
        assert!(rejected.load(Ordering::SeqCst));
        assert!(calls.load(Ordering::SeqCst) > 12);
    }
    #[tokio::test]
    async fn paused_pipeline_stays_idle_and_cancel_interrupts_pending_reads() {
        let control = Arc::new(TransferControl::default());
        control.set(1);
        let calls = Arc::new(AtomicUsize::new(0));
        let count = calls.clone();
        let gate = control.clone();
        let task = tokio::spawn(async move {
            let mut bytes = Vec::new();
            copy_ranges(
                &mut bytes,
                CHUNK as u64 * 32,
                gate,
                move |_, _| {
                    count.fetch_add(1, Ordering::SeqCst);
                    async { std::future::pending::<Result<Vec<u8>>>().await }
                },
                |_| {},
            )
            .await
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        control.set(0);
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(calls.load(Ordering::SeqCst), READ_WINDOW);
        control.set(2);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
    }
    #[tokio::test]
    async fn invalid_chunk_is_not_hidden_by_compatibility_retry() {
        for invalid in [Vec::new(), vec![0; CHUNK as usize + 1]] {
            let mut target = Vec::new();
            assert!(
                copy_ranges(
                    &mut target,
                    CHUNK as u64,
                    Arc::default(),
                    move |_, _| {
                        let bytes = invalid.clone();
                        async move { Ok(bytes) }
                    },
                    |_| {}
                )
                .await
                .is_err()
            );
            assert!(target.is_empty());
        }
    }
}
