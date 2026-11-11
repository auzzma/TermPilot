use anyhow::{bail, Result};
use tokio::io::BufReader;
fn main() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("TermPilot runtime");
    runtime.block_on(run());
    runtime.shutdown_timeout(std::time::Duration::from_millis(250));
}
async fn run() {
    let result: Result<()> = async {
        match std::env::args().nth(1).as_deref() {
            Some("ai") => termpilot_ai::serve().await?,
            Some("ai-mcp") => termpilot_ai::mcp::stdio_proxy().await?,
            Some("ai-tool") => termpilot_ai::mcp::tool_cli().await?,
            Some("ai-script") => termpilot_ai::script_worker::serve()?,
            #[cfg(unix)]
            Some("ssh-broker") => termpilot_engine::local::broker().await?,
            #[cfg(unix)]
            Some("ssh-files") => termpilot_engine::local::files().await?,
            #[cfg(unix)]
            Some("ssh-terminal") => {
                termpilot_engine::local::terminal(
                    std::env::args()
                        .nth(2)
                        .ok_or_else(|| anyhow::anyhow!("Private configuration pipe required"))?
                        .into(),
                )
                .await?
            }
            Some("ssh") => {
                termpilot_engine::worker::serve(tokio::io::stdin(), tokio::io::stdout(), None, None)
                    .await?
            }
            Some("batch") => {
                if let Err(error) =
                    termpilot_engine::batch::serve(tokio::io::stdin(), tokio::io::stdout()).await
                {
                    termpilot_engine::ipc::write_json(
                        &mut tokio::io::stdout(),
                        &serde_json::json!({"type":"batchFinished", "error":error.to_string()}),
                    )
                    .await?;
                }
            }
            Some("screen-sharing") => termpilot_engine::screen::run().await?,
            #[cfg(any(target_os = "macos", windows))]
            Some("screen-media-broker") => termpilot_engine::screen::hp::broker::run().await?,
            Some("keygen") => {
                let cfg = termpilot_engine::ipc::read_json(&mut BufReader::new(tokio::io::stdin()))
                    .await?
                    .ok_or_else(|| anyhow::anyhow!("Missing configuration"))?;
                let result =
                    tokio::task::spawn_blocking(move || termpilot_engine::keygen::generate(&cfg))
                        .await??;
                termpilot_engine::ipc::write_json(&mut tokio::io::stdout(), &result).await?;
            }
            _ => bail!("Unknown TermPilot engine mode"),
        }
        Ok(())
    }
    .await;
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
