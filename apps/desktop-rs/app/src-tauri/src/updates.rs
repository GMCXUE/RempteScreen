//! Signed release metadata and verified native installers. No administration credentials here.
use std::{fs, io::{Read, Write}, path::{Path, PathBuf}, sync::{Mutex, atomic::{AtomicBool, Ordering}}, time::{Duration, SystemTime, UNIX_EPOCH}};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tauri::{Emitter, Manager};

#[derive(Default)]
pub struct UpdateState { busy: AtomicBool, release: Mutex<Option<Value>>, prepared: Mutex<Option<PathBuf>> }
struct Busy<'a>(&'a AtomicBool);
impl Drop for Busy<'_> { fn drop(&mut self) { self.0.store(false, Ordering::SeqCst); } }
fn acquire(state: &UpdateState) -> Result<Busy<'_>, String> {
    if state.busy.swap(true, Ordering::SeqCst) { return Err("更新操作正在进行".into()); } Ok(Busy(&state.busy))
}
fn err(e: impl std::fmt::Display) -> String { e.to_string() }
fn version() -> Value { serde_json::from_str(include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../config/client-version.json"))).unwrap() }
fn public_key() -> Value { serde_json::from_str(include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../config/update-public-key.json"))).unwrap() }
fn platform() -> &'static str { if cfg!(target_os="windows") { "windows" } else { "macos" } }
fn arch() -> &'static str { if cfg!(target_arch="aarch64") { "arm64" } else { "x64" } }
fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64 }
fn directory(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let path = app.path().app_local_data_dir().map_err(err)?.join("updates"); fs::create_dir_all(&path).map_err(err)?; Ok(path)
}
fn agent() -> ureq::Agent { ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(10)).timeout_read(Duration::from_secs(30)).redirects(0).build() }
fn bytes64(value: &Value, field: &str) -> Result<Vec<u8>, String> { STANDARD.decode(value[field].as_str().ok_or("更新签名无效")?).map_err(err) }
fn validate(envelope: &Value, cached: bool) -> Result<Value, String> { validate_with_key(envelope,cached,&public_key()) }
fn validate_with_key(envelope: &Value, cached: bool, key: &Value) -> Result<Value, String> {
    if envelope["algorithm"] != "ed25519" || envelope["keyId"] != key["keyId"] { return Err("更新签名无效".into()); }
    let payload = bytes64(envelope, "payload")?;
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, bytes64(&key,"publicKey")?).verify(&payload, &bytes64(envelope,"signature")?).map_err(|_| "更新签名无效")?;
    let value: Value = serde_json::from_slice(&payload).map_err(err)?;
    if value["schema"] != 1 || value["target"]["platform"] != platform() || value["target"]["arch"] != arch() || value["target"]["channel"] != version()["channel"] ||
        (!cached && (value["expiresAt"].as_u64().unwrap_or(0) < now() || value["checkedAt"].as_u64().unwrap_or(u64::MAX) > now()+60000)) { return Err("更新信息已失效，请重试".into()); }
    let release = &value["release"];
    if !release.is_null() {
        let sha = release["sha256"].as_str().unwrap_or("");
        let id = release["id"].as_str().unwrap_or("");
        if sha.len()!=64 || !sha.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) ||
            id.len()!=22 || !id.starts_with("rel_") || !id[4..].bytes().all(|b| b.is_ascii_hexdigit()) ||
            release["downloadPath"] != format!("/v1/updates/packages/{id}") ||
            release["platform"] != platform() || release["arch"] != arch() || release["channel"] != version()["channel"] ||
            release["sizeBytes"].as_u64().filter(|n| *n>0 && *n<=512*1024*1024).is_none() ||
            release["buildCode"].as_u64().filter(|n| *n>0 && *n<=2147483647).is_none() ||
            !release["notes"].is_string() || !release["versionName"].is_string() || !release["forceUpdate"].is_boolean() { return Err("更新信息无效".into()); }
    }
    Ok(value)
}
fn newer(release: &Value) -> bool { release["buildCode"].as_u64().unwrap_or(0) > version()["buildCode"].as_u64().unwrap() }
#[tauri::command]
pub fn update_info() -> Value { let mut v=version();v["platform"]=json!(platform());v["arch"]=json!(arch());v }
#[tauri::command]
pub async fn update_check(app: tauri::AppHandle) -> Result<Value,String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state=app.state::<UpdateState>(); let _busy=acquire(&state)?;
        let cache=directory(&app)?.join("required.json");
        // A fully written staging file is also a valid fallback if Windows replacement
        // was interrupted. Only authenticated mandatory records may enforce the gate.
        let fallback=[cache.clone(),cache.with_extension("tmp")].iter().filter_map(|path|
            fs::read(path).ok().and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|envelope| validate(&envelope,true).ok()).map(|p| p["release"].clone())
            .filter(|r| newer(r) && r["forceUpdate"]==true)).max_by_key(|r|r["buildCode"].as_u64());
        let mut verified_required=None;
        let result=(|| -> Result<Value,String> {
            let response=agent().get(&format!("{}/v1/updates/check",super::api::SERVER_URL)).query("platform",platform()).query("arch",arch()).query("channel",version()["channel"].as_str().unwrap()).query("buildCode",&version()["buildCode"].to_string()).call().map_err(err)?;
            let mut bytes=Vec::new();response.into_reader().take(100_000).read_to_end(&mut bytes).map_err(err)?;
            let envelope: Value=serde_json::from_slice(&bytes).map_err(err)?;
            let payload=validate(&envelope,false)?;let release=payload["release"].clone();
            if newer(&release) && release["forceUpdate"]==true {
                verified_required=Some(release.clone());
                let temporary=cache.with_extension("tmp");fs::write(&temporary,&bytes).map_err(err)?;
                // Windows cannot atomically rename over an existing file; retain the old gate on failure.
                if cache.exists() { fs::copy(&temporary,&cache).map_err(err)?;let _=fs::remove_file(temporary); }
                else { fs::rename(temporary,&cache).map_err(err)?; }
            } else { for path in [&cache,&cache.with_extension("tmp")] { if path.exists() {fs::remove_file(path).map_err(err)?;} } }
            Ok(if newer(&release) { release } else { Value::Null })
        })();
        let (release,error)=match result { Ok(r)=>(r,String::new()),Err(_)=>(verified_required.or(fallback).unwrap_or(Value::Null),"暂时无法检查更新，请检查网络后重试".into()) };
        let mut current=state.release.lock().unwrap();
        if current.as_ref().map(|r| &r["sha256"]) != Some(&release["sha256"]) { *state.prepared.lock().unwrap()=None; }
        *current=if release.is_null(){None}else{Some(release.clone())};
        Ok(json!({"release":release,"error":error}))
    }).await.map_err(err)?
}
fn verify_file(path: &Path, release: &Value) -> Result<(),String> {
    let mut file=fs::File::open(path).map_err(err)?;
    if file.metadata().map_err(err)?.len()!=release["sizeBytes"].as_u64().unwrap() {return Err("安装包大小不符".into());}
    let mut hash=Sha256::new();let mut buffer=[0;65536];loop {let n=file.read(&mut buffer).map_err(err)?;if n==0{break;}hash.update(&buffer[..n]);}
    if format!("{:x}",hash.finalize())!=release["sha256"].as_str().unwrap() {return Err("安装包校验失败，请重新下载".into());} Ok(())
}
#[tauri::command]
pub async fn update_download(app: tauri::AppHandle) -> Result<(),String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state=app.state::<UpdateState>();let _busy=acquire(&state)?;
        let release=state.release.lock().unwrap().clone().ok_or("请先检查更新")?;
        let dir=directory(&app)?;let extension=if cfg!(target_os="windows"){ "exe" } else { "zip" };
        let path=dir.join(format!("{}.{}",release["sha256"].as_str().unwrap(),extension));let partial=path.with_extension("part");
        let result=(|| -> Result<(),String> {
            let response=agent().get(&format!("{}{}",super::api::SERVER_URL,release["downloadPath"].as_str().unwrap())).call().map_err(|_|"安装包暂不可用，请重新检查更新")?;
            let mut input=response.into_reader();let mut output=fs::File::create(&partial).map_err(err)?;
            let size=release["sizeBytes"].as_u64().unwrap();let mut count=0u64;let mut buffer=[0;65536];let mut last=std::time::Instant::now();
            loop {let n=input.read(&mut buffer).map_err(err)?;if n==0{break;}count+=n as u64;if count>size{return Err("安装包大小不符".into());}output.write_all(&buffer[..n]).map_err(err)?;
                if last.elapsed()>Duration::from_millis(100) {let _=app.emit("app-update:progress",count as f64/size as f64);last=std::time::Instant::now();}}
            output.sync_all().map_err(err)?;drop(output);verify_file(&partial,&release)?;
            if path.exists(){fs::remove_file(&path).map_err(err)?;}fs::rename(&partial,&path).map_err(err)?;
            *state.prepared.lock().unwrap()=Some(path);let _=app.emit("app-update:progress",1.0);Ok(())
        })();let _=fs::remove_file(partial);result
    }).await.map_err(err)?
}

#[cfg(target_os="macos")]
fn prepare_macos(app: &tauri::AppHandle, package: &Path, release: &Value) -> Result<(PathBuf,PathBuf,PathBuf),String> {
    use std::os::unix::fs::PermissionsExt;
    let executable=std::env::current_exe().map_err(err)?;
    let installed=executable.parent().and_then(Path::parent).and_then(Path::parent).ok_or("请从已安装的 RemoteScreen.app 启动")?.to_path_buf();
    if installed.extension().and_then(|e|e.to_str())!=Some("app") {return Err("请先将 RemoteScreen.app 放入应用程序目录".into());}
    let parent=installed.parent().ok_or("应用目录无效")?;
    let stage=parent.join(format!(".RemoteScreen-update-{}",now()));fs::create_dir(&stage).map_err(|_|"应用目录不可写，请将 RemoteScreen 移至当前用户的应用程序目录后重试")?;
    let result=(|| -> Result<(),String> {
        let mut archive=zip::ZipArchive::new(fs::File::open(package).map_err(err)?).map_err(err)?;
        let mut expanded=0u64;
        for i in 0..archive.len() {
            let mut entry=archive.by_index(i).map_err(err)?;
            let relative=entry.enclosed_name().ok_or("安装包包含无效路径")?.to_path_buf();
            if relative.components().next().and_then(|c|c.as_os_str().to_str())!=Some("RemoteScreen.app") {return Err("安装包必须只包含 RemoteScreen.app".into());}
            if entry.unix_mode().map(|m|m&0o170000==0o120000).unwrap_or(false) {return Err("安装包包含不支持的符号链接".into());}
            expanded=expanded.checked_add(entry.size()).ok_or("安装包过大")?;if expanded>2*1024*1024*1024{return Err("安装包过大".into());}
            let destination=stage.join(relative);
            if entry.is_dir(){fs::create_dir_all(&destination).map_err(err)?;} else {
                fs::create_dir_all(destination.parent().unwrap()).map_err(err)?;
                let mut file=fs::File::create(&destination).map_err(err)?;std::io::copy(&mut entry,&mut file).map_err(err)?;
                fs::set_permissions(&destination,fs::Permissions::from_mode(entry.unix_mode().unwrap_or(0o644)&0o777)).map_err(err)?;
            }
        }
        let incoming=stage.join("RemoteScreen.app");
        let embedded:Value=serde_json::from_slice(&fs::read(incoming.join("Contents/Resources/update-version.json")).map_err(err)?).map_err(err)?;
        if embedded["buildCode"]!=release["buildCode"] || embedded["versionName"]!=release["versionName"] {return Err("安装包版本不符".into());}
        let id=std::process::Command::new("/usr/libexec/PlistBuddy").args(["-c","Print :CFBundleIdentifier"]).arg(incoming.join("Contents/Info.plist")).output().map_err(err)?;
        if !id.status.success() || String::from_utf8_lossy(&id.stdout).trim()!="com.remotescreen.rs" {return Err("安装包不属于 RemoteScreen".into());}
        if !std::process::Command::new("/usr/bin/codesign").args(["--verify","--deep","--strict"]).arg(&incoming).status().map_err(err)?.success(){return Err("安装包签名校验失败".into());}
        Ok(())
    })();
    if let Err(error)=result {let _=fs::remove_dir_all(&stage);return Err(error);}
    let helper=directory(app)?.join("install-macos.sh");
    fs::write(&helper,include_str!("update-macos.sh")).map_err(err)?;
    Ok((helper,installed,stage))
}
#[tauri::command]
pub async fn update_install(app: tauri::AppHandle) -> Result<(),String> {
    let state=app.state::<UpdateState>();let _busy=acquire(&state)?;
    let release=state.release.lock().unwrap().clone().ok_or("请先检查更新")?;
    let path=state.prepared.lock().unwrap().clone().ok_or("请先下载更新")?;
    let package=path.clone();let record=release.clone();
    tauri::async_runtime::spawn_blocking(move || verify_file(&package,&record)).await.map_err(err)??;
    #[cfg(target_os="macos")]
    let mac={let handle=app.clone();let file=path.clone();let record=release.clone();tauri::async_runtime::spawn_blocking(move||prepare_macos(&handle,&file,&record)).await.map_err(err)??};
    let sessions=app.state::<super::AppState>();
    super::friend_call_stop(Some(false),sessions.clone()).await?;
    super::stop_publish(sessions.clone())?;super::stop_watch(sessions.clone())?;super::stop_file_transfer(sessions);
    #[cfg(target_os="windows")]
    std::process::Command::new(&path).spawn().map_err(|e|format!("无法打开安装程序：{e}"))?;
    #[cfg(target_os="macos")]
    std::process::Command::new("/bin/sh").arg(&mac.0).arg(std::process::id().to_string()).arg(&mac.1).arg(&mac.2)
        .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null())
        .stderr(fs::File::create(directory(&app)?.join("install.log")).map_err(err)?).spawn().map_err(err)?;
    app.exit(0);Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair,KeyPair};
    fn signed(expired:bool)->(Value,Value) {
        let pair=Ed25519KeyPair::from_seed_unchecked(&[7u8;32]).unwrap();
        let key=json!({"keyId":"test","publicKey":STANDARD.encode(pair.public_key().as_ref())});
        let payload=json!({"schema":1,"target":{"platform":platform(),"arch":arch(),"channel":version()["channel"]},
            "checkedAt":now(),"expiresAt":if expired{1}else{now()+900000},
            "release":{"id":"rel_aaaaaaaaaaaaaaaaaa","downloadPath":"/v1/updates/packages/rel_aaaaaaaaaaaaaaaaaa",
                "platform":platform(),"arch":arch(),"channel":"stable","buildCode":2026101202u64,"versionName":"0.2.1",
                "sizeBytes":3,"sha256":format!("{:x}",Sha256::digest(b"abc")),"notes":"修复通话","forceUpdate":true}});
        let bytes=serde_json::to_vec(&payload).unwrap();
        (json!({"algorithm":"ed25519","keyId":"test","payload":STANDARD.encode(&bytes),"signature":STANDARD.encode(pair.sign(&bytes).as_ref())}),key)
    }
    #[test]
    fn signatures_and_expiry_gate_updates() {
        let (mut envelope,key)=signed(false);
        assert!(validate_with_key(&envelope,false,&key).is_ok());
        envelope["payload"]=json!(STANDARD.encode(b"tampered"));
        assert!(validate_with_key(&envelope,false,&key).is_err());
        let (expired,key)=signed(true);
        assert!(validate_with_key(&expired,false,&key).is_err());
        assert!(validate_with_key(&expired,true,&key).is_ok());
    }
    #[test]
    fn installer_hash_is_checked_again_before_execution() {
        let (envelope,key)=signed(false);let payload=validate_with_key(&envelope,false,&key).unwrap();
        let path=std::env::temp_dir().join(format!("rs-update-hash-{}",std::process::id()));
        fs::write(&path,b"abc").unwrap();assert!(verify_file(&path,&payload["release"]).is_ok());
        fs::write(&path,b"abd").unwrap();assert!(verify_file(&path,&payload["release"]).is_err());
        fs::write(&path,b"long").unwrap();assert!(verify_file(&path,&payload["release"]).is_err());
        fs::remove_file(path).unwrap();
    }
}
