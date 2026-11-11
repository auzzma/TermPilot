#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(if std::env::var_os("TERMPILOT_RDP_DIAGNOSTICS").is_some() {
            "warn,ironrdp_rdpsnd=debug,ironrdp_rdpdr=debug"
        } else {
            "warn"
        })
        .init();
    let _ = termpilot_rdp::serve(tokio::io::stdin(), tokio::io::stdout()).await;
}
