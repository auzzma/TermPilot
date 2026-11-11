use std::{env, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-changed=platform/macos/MediaAdapter.swift");
    println!("cargo:rerun-if-env-changed=SWIFTC");
    let target = env::var("TARGET").unwrap();
    if target.contains("android") {
        println!("cargo:rerun-if-env-changed=TERMPILOT_MOBILE_MEDIA_LIB_DIR");
        if let Ok(path) = env::var("TERMPILOT_MOBILE_MEDIA_LIB_DIR") {
            println!("cargo:rustc-link-search=native={path}");
        }
        println!("cargo:rustc-link-lib=dylib=termpilot_media");
        return;
    }
    let ios = target.contains("apple-ios");
    if !target.ends_with("apple-darwin") && !ios {
        return;
    }
    let arch = if target.starts_with("aarch64") {
        "arm64"
    } else {
        "x86_64"
    };
    let swift_target = if ios {
        format!(
            "{arch}-apple-ios17.0{}",
            if target.ends_with("-sim") {
                "-simulator"
            } else {
                ""
            }
        )
    } else {
        format!("{arch}-apple-macosx14.0")
    };
    let sdk = if ios {
        let name = if target.ends_with("-sim") {
            "iphonesimulator"
        } else {
            "iphoneos"
        };
        let result = Command::new("xcrun")
            .args(["--sdk", name, "--show-sdk-path"])
            .output()
            .unwrap();
        assert!(result.status.success());
        Some(String::from_utf8(result.stdout).unwrap().trim().to_owned())
    } else {
        None
    };
    let swift = env::var("SWIFTC").unwrap_or_else(|_| "swiftc".into());
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let library = out.join("libTermPilotMedia.a");
    let mut compiler = Command::new(&swift);
    if let Some(sdk) = &sdk {
        compiler.args(["-sdk", sdk]);
    }
    let status = compiler
        .args([
            "-O",
            "-parse-as-library",
            "-emit-library",
            "-static",
            "platform/macos/MediaAdapter.swift",
            "-target",
            &swift_target,
            "-module-name",
            "TermPilotMedia",
            "-o",
        ])
        .arg(&library)
        // Keep compiler caches inside Cargo's build directory, including in
        // sandboxed builds and separate ARM64/Intel target builds.
        .arg("-module-cache-path")
        .arg(out.join("swift-module-cache"))
        .status()
        .expect("Swift compiler for macOS media adapter");
    assert!(status.success(), "System media adapter compilation failed");
    let info = Command::new(&swift)
        .args(["-print-target-info", "-target", &swift_target])
        .output()
        .unwrap();
    assert!(info.status.success());
    let info: serde_json::Value = serde_json::from_slice(&info.stdout).unwrap();
    for path in info["paths"]["runtimeLibraryPaths"].as_array().unwrap() {
        println!("cargo:rustc-link-search=native={}", path.as_str().unwrap());
    }
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=TermPilotMedia");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    // Used by packaged engine and test executables; no Xcode runtime path.
    println!("cargo:rustc-link-arg=-Wl,-rpath,@executable_path/../../Frameworks");
}
