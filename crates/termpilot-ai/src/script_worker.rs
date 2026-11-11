//! Isolated JavaScript worker. No filesystem, networking, modules, Node, or
//! Python APIs are installed in this context. Every host effect is private IPC.
use anyhow::{ensure, Context as _, Result};
use rquickjs::{Context, Exception, Function, Promise, Runtime, Value};
use serde_json::{json, Value as Json};
use std::{
    io::{BufRead, Write},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
fn line(input: &mut impl BufRead) -> Result<Json> {
    let mut bytes = vec![];
    loop {
        let part = input.fill_buf()?;
        ensure!(!part.is_empty(), "Script host disconnected");
        let count = part
            .iter()
            .position(|b| *b == 10)
            .map(|n| n + 1)
            .unwrap_or(part.len());
        ensure!(
            bytes.len() + count <= 2 * 1024 * 1024,
            "Script IPC limit exceeded"
        );
        bytes.extend_from_slice(&part[..count]);
        input.consume(count);
        if bytes.last() == Some(&10) {
            return Ok(serde_json::from_slice(&bytes)?);
        }
    }
}
pub fn serve() -> Result<()> {
    let mut input = std::io::stdin().lock();
    serve_io(
        &mut input,
        std::io::stdout(),
        Arc::new(AtomicBool::new(false)),
    )
}
/// In-process mobile execution with the same memory, time and host-effect limits.
pub fn serve_io(
    input: &mut impl BufRead,
    output: impl Write + Send + 'static,
    cancel: Arc<AtomicBool>,
) -> Result<()> {
    let output = Arc::new(std::sync::Mutex::new(output));
    let init = line(input)?;
    let source = init["source"].as_str().context("Missing script source")?;
    ensure!(source.len() <= 1024 * 1024, "Script source too large");
    let runtime = Runtime::new()?;
    runtime.set_memory_limit(64 * 1024 * 1024);
    runtime.set_max_stack_size(1024 * 1024);
    let start = Instant::now();
    let last = Arc::new(AtomicU64::new(0));
    let seen = last.clone();
    runtime.set_interrupt_handler(Some(Box::new(move || {
        cancel.load(Ordering::Acquire)
            || start
                .elapsed()
                .as_millis()
                .saturating_sub(u128::from(seen.load(Ordering::Relaxed)))
                > 5000
    })));
    let context = Context::full(&runtime)?;
    let result = context.with(|ctx| -> Result<()> {
        let sent = Arc::new(AtomicU64::new(0));
        let writer = output.clone();
        let send = Function::new(
            ctx.clone(),
            move |ctx: rquickjs::Ctx<'_>, message: String| -> rquickjs::Result<()> {
                if message.len() > 1024 * 1024 || sent.fetch_add(1, Ordering::Relaxed) >= 20000 {
                    return Err(Exception::throw_message(
                        &ctx,
                        "Script message budget exceeded",
                    ));
                }
                let mut out = writer.lock().unwrap();
                writeln!(out, "{message}")
                    .and_then(|_| out.flush())
                    .map_err(|_| Exception::throw_message(&ctx, "Script host disconnected"))
            },
        )?;
        ctx.globals().set("__termpilotSend", send)?;
        ctx.globals().set(
            "__termpilotInitial",
            serde_json::to_string(&init["snapshot"])?,
        )?;
        let deliver: Function = ctx.eval(include_str!("script_bootstrap.js"))?;
        let trimmed = source.trim();
        let wrapped = if trimmed.starts_with("(async") || trimmed.starts_with("( async") {
            trimmed.to_owned()
        } else {
            format!("(async()=>{{\n{source}\n;if(typeof main==='function') await main();\n}})()")
        };
        let evaluated: Value = ctx.eval(wrapped)?;
        let resolve: Function = ctx.eval("value => Promise.resolve(value)")?;
        let promise: Promise = resolve.call((evaluated,))?;
        loop {
            while ctx.execute_pending_job() {}
            if let Some(result) = promise.result::<Value>() {
                result.map_err(|_| {
                    let error = ctx.catch();
                    anyhow::anyhow!(
                        "Script failed: {}",
                        error
                            .as_exception()
                            .and_then(|e| e.message())
                            .unwrap_or_else(|| "JavaScript error".into())
                    )
                })?;
                break;
            }
            let response = line(input)?;
            last.store(start.elapsed().as_millis() as u64, Ordering::Relaxed);
            deliver.call::<_, ()>((response.to_string(),))?;
            ensure!(
                start.elapsed() < Duration::from_secs(86400),
                "Script exceeded its duration limit"
            );
        }
        Ok(())
    });
    let mut out = output.lock().unwrap();
    writeln!(
        out,
        "{}",
        match &result {
            Ok(_) => json!({"type":"completed"}),
            Err(e) => json!({"type":"failed","error":e.to_string()}),
        }
    )?;
    out.flush()?;
    result
}
