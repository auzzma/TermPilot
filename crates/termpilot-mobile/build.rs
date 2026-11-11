fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // The engine's static Swift adapter is also linked into this crate.
        // Cargo does not propagate a dependency's rustc-link-arg to consumers.
        // Use the OS runtime, including when Intel tests run under Rosetta.
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
}
