fn main() {
    println!(
        "cargo:rustc-env=RS_BUILD_TARGET={}",
        std::env::var("TARGET").unwrap()
    );
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let source = "../../../../tools/macos-audio-capture/main.swift";
        println!("cargo:rerun-if-changed={source}");
        let target = std::env::var("TARGET").unwrap();
        let arch = if target.starts_with("aarch64") {
            "arm64"
        } else {
            "x86_64"
        };
        std::fs::create_dir_all("binaries").unwrap();
        let binary = format!("binaries/macos-audio-capture-{target}");
        let status = std::process::Command::new("xcrun")
            .args([
                "swiftc",
                "-O",
                "-target",
                &format!("{arch}-apple-macosx13.0"),
                source,
                "-o",
                &binary,
            ])
            .status()
            .expect("无法运行 swiftc 编译系统音频采集器");
        assert!(status.success(), "系统音频采集器编译失败");
    }
    tauri_build::build()
}
