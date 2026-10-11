fn main() {
    println!(
        "cargo:rustc-env=RS_BUILD_TARGET={}",
        std::env::var("TARGET").unwrap()
    );
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let target = std::env::var("TARGET").unwrap();
        let arch = if target.starts_with("aarch64") {
            "arm64"
        } else {
            "x86_64"
        };
        std::fs::create_dir_all("binaries").unwrap();
        println!("cargo:rerun-if-changed=src/capture_permissions.m");
        let out = std::env::var("OUT_DIR").unwrap();
        let object = format!("{out}/capture_permissions.o");
        println!("cargo:rerun-if-changed=src/notification_bridge.m");
        let notification_object=format!("{out}/notification_bridge.o");
        let notification_status=std::process::Command::new("xcrun").args(["clang","-fobjc-arc","-fblocks","-arch",arch,"-mmacosx-version-min=13.0","-c","src/notification_bridge.m","-o",&notification_object]).status().unwrap();
        assert!(notification_status.success(),"通知桥接编译失败");
        let archive = format!("{out}/librs_capture_permissions.a");
        let status = std::process::Command::new("xcrun").args([
            "clang", "-fobjc-arc", "-fblocks", "-arch", arch,
            "-mmacosx-version-min=13.0", "-c", "src/capture_permissions.m", "-o", &object,
        ]).status().expect("无法编译主应用权限桥接");
        assert!(status.success(), "主应用权限桥接编译失败");
        let status = std::process::Command::new("xcrun").args([
            "libtool", "-static", "-o", &archive, &object, &notification_object,
        ]).status().expect("无法打包主应用权限桥接");
        assert!(status.success(), "主应用权限桥接打包失败");
        println!("cargo:rustc-link-search=native={out}");
        println!("cargo:rustc-link-lib=static=rs_capture_permissions");
        println!("cargo:rustc-link-lib=framework=AVFoundation");
        println!("cargo:rustc-link-lib=framework=Foundation");
        println!("cargo:rustc-link-lib=framework=UserNotifications");
        println!("cargo:rustc-link-lib=framework=AppKit");
        for (name, source) in [
            ("macos-audio-capture", "../../../../tools/macos-audio-capture/main.swift"),
            ("macos-camera-capture", "../../../../tools/macos-camera-capture/main.swift"),
        ] {
            println!("cargo:rerun-if-changed={source}");
            let binary = format!("binaries/{name}-{target}");
            println!("cargo:rerun-if-changed=HelperInfo.plist");
            let helper_plist = format!("{out}/{name}-Info.plist");
            std::fs::write(&helper_plist,
                std::fs::read_to_string("HelperInfo.plist").unwrap()
                    .replace("__HELPER_NAME__", name)).unwrap();
            let status = std::process::Command::new("xcrun")
                .args([
                    "swiftc",
                    "-O",
                    "-target",
                    &format!("{arch}-apple-macosx13.0"),
                    source,
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", &helper_plist,
                    "-o",
                    &binary,
                ])
                .status()
                .unwrap_or_else(|_| panic!("无法运行 swiftc 编译 {name}"));
            assert!(status.success(), "{name} 编译失败");
        }
    }
    tauri_build::build()
}
