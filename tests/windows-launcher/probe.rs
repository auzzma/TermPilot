// A dependency-free child executable for validating the real release launcher.
use std::{env, fs};
fn main() {
    let args: Vec<_> = env::args().skip(1).collect();
    assert_eq!(
        args,
        ["", "plain", "中文 空格", "quote\"inside", "trailing\\"]
    );
    let exe = env::current_exe().unwrap();
    assert_eq!(env::current_dir().unwrap(), exe.parent().unwrap());
    fs::write(
        env::var_os("TERMPILOT_LAUNCHER_TEST_RESULT").unwrap(),
        "passed",
    )
    .unwrap();
    std::process::exit(37);
}
