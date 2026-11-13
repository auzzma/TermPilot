//! Repairs only verified original ciphertext. Does not upgrade the cloud format.
//! Usage: cargo run -p termpilot-core --release --example sync_repair -- DATA_DIRECTORY
fn main() {
    let Some(directory) = std::env::args().nth(1) else {
        eprintln!("Usage: sync_repair DATA_DIRECTORY");
        std::process::exit(2);
    };
    let request = serde_json::json!({"apiVersion":termpilot_core::API_VERSION,"method":"sync.repair","directory":directory});
    match termpilot_core::dispatch(&request) {
        Ok(value) => println!(
            "{}",
            serde_json::json!({"ok":true,"recovery":value["objectRecovery"]})
        ),
        Err(error) => {
            println!(
                "{}",
                serde_json::json!({"ok":false,"code":error.code,"message":error.message})
            );
            std::process::exit(1);
        }
    }
}
