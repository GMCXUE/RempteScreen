//! Request privacy access in the host application, never in a helper process.
extern "C" { fn rs_request_capture_permission(camera: i32) -> i32; }

/// Must run off the main thread: the native bridge dispatches the request there.
pub fn request(camera: bool) -> Result<(), String> {
    let status = unsafe { rs_request_capture_permission(i32::from(camera)) };
    crate::publisher::log_to_file(&format!("[capture-permission] main-app {} status={status}",
        if camera { "camera" } else { "microphone" }));
    if status == 3 { return Ok(()); }
    let device = if camera { "摄像头" } else { "麦克风" };
    if status == 4 { return Err(format!("{device}授权等待超时，请重试")); }
    let pane = if camera { "Privacy_Camera" } else { "Privacy_Microphone" };
    let _ = std::process::Command::new("open")
        .arg(format!("x-apple.systempreferences:com.apple.preference.security?{pane}"))
        .status();
    Err(format!("请在系统设置的隐私与安全性中允许 RemoteScreen 使用{device}；已开启时请退出并重新打开应用"))
}
