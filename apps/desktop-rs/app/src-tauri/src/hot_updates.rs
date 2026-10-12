//! Signed, exact-native-build web assets. Application binaries and credentials are never replaced.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    borrow::Cow,
    collections::BTreeMap,
    fs,
    io::Read,
    path::PathBuf,
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{
    utils::assets::{AssetKey, AssetsIter, CspHash},
    Assets, Manager, Wry,
};
const MAX: u64 = 8 * 1024 * 1024;
const REQUIRED: &[&str] = &[
    "index.html",
    "app.js",
    "style.css",
    "hot-updates.js",
    "updates.js",
    "viewer.html",
    "friend-call.html",
    "chat-history.html",
];
fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn platform() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else {
        "macos"
    }
}
fn arch() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x64"
    }
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn root() -> Result<PathBuf, String> {
    Ok(dirs::data_local_dir()
        .ok_or("更新目录不可用")?
        .join("com.remotescreen.rs")
        .join("ui-updates")
        .join(super::updates::version()["buildCode"].to_string()))
}
#[derive(Default, Serialize, Deserialize, Clone)]
struct Selection {
    active: u32,
    good: u32,
    booting: u32,
    blocked: Vec<u32>,
}
pub struct HotUpdateState {
    directory: PathBuf,
    selection: Mutex<Selection>,
    offered: Mutex<Option<Value>>,
    running: u32,
    rollback: bool,
    operation: Mutex<()>,
}
struct Overlay {
    bundled: Option<Box<dyn Assets<Wry>>>,
    files: BTreeMap<String, Vec<u8>>,
}
impl Assets<Wry> for Overlay {
    fn setup(&self, app: &tauri::App<Wry>) {
        if let Some(a) = &self.bundled {
            a.setup(app);
        }
    }
    fn get(&self, key: &AssetKey) -> Option<Cow<'_, [u8]>> {
        self.files
            .get(key.as_ref())
            .map(|v| Cow::Borrowed(v.as_slice()))
            .or_else(|| self.bundled.as_ref()?.get(key))
    }
    fn iter(&self) -> Box<AssetsIter<'_>> {
        Box::new(
            self.files
                .iter()
                .map(|(k, v)| (Cow::Borrowed(k.as_str()), Cow::Borrowed(v.as_slice())))
                .chain(
                    self.bundled
                        .iter()
                        .flat_map(|a| a.iter())
                        .filter(|(k, _)| !self.files.contains_key(k.as_ref())),
                ),
        )
    }
    fn csp_hashes(&self, key: &AssetKey) -> Box<dyn Iterator<Item = CspHash<'_>> + '_> {
        match &self.bundled {
            Some(a) => a.csp_hashes(key),
            None => Box::new(std::iter::empty()),
        }
    }
}
fn atomic_write(dir: &std::path::Path, name: &str, bytes: &[u8]) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(error)?;
    let temp = dir.join(format!("{name}.tmp"));
    let mut f = fs::File::create(&temp).map_err(error)?;
    use std::io::Write;
    f.write_all(bytes).map_err(error)?;
    f.sync_all().map_err(error)?;
    drop(f);
    // Windows rename cannot replace an existing file. A missing pointer safely loads bundled assets.
    let dest = dir.join(name);
    if dest.exists() {
        fs::remove_file(&dest).map_err(error)?;
    }
    fs::rename(temp, dest).map_err(error)
}
fn save(dir: &std::path::Path, s: &Selection) -> Result<(), String> {
    atomic_write(
        dir,
        "selection.json",
        &serde_json::to_vec(s).map_err(error)?,
    )
}
fn recover(s: &mut Selection) -> bool {
    if s.booting == 0 {
        return false;
    }
    let failed = s.booting;
    if !s.blocked.contains(&failed) {
        s.blocked.push(failed);
    }
    s.active = if s.good == failed { 0 } else { s.good };
    s.good = s.active;
    s.booting = 0;
    true
}
fn verify(envelope: &Value, cached: bool, key: &Value) -> Result<Value, String> {
    if envelope["algorithm"] != "ed25519" || envelope["keyId"] != key["keyId"] {
        return Err("更新签名无效".into());
    }
    let decode = |v: &Value| {
        STANDARD
            .decode(v.as_str().ok_or("更新签名无效")?)
            .map_err(error)
    };
    let bytes = decode(&envelope["payload"])?;
    if bytes.len() as u64 > MAX {
        return Err("界面资源过大".into());
    }
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, decode(&key["publicKey"])?)
        .verify(&bytes, &decode(&envelope["signature"])?)
        .map_err(|_| "更新签名无效")?;
    let payload: Value = serde_json::from_slice(&bytes).map_err(error)?;
    let t = &payload["target"];
    if payload["schema"] != 1
        || payload["kind"] != "hot-update"
        || t["platform"] != platform()
        || t["arch"] != arch()
        || t["channel"] != super::updates::version()["channel"]
        || t["nativeBuild"] != super::updates::version()["buildCode"]
        || (!cached
            && (payload["expiresAt"].as_u64().unwrap_or(0) < now()
                || payload["checkedAt"].as_u64().unwrap_or(u64::MAX) > now() + 60000))
    {
        return Err("更新信息与当前版本不兼容".into());
    }
    if !payload["patch"].is_null() {
        assets(&payload["patch"])?;
    }
    Ok(payload)
}
fn assets(patch: &Value) -> Result<BTreeMap<String, Vec<u8>>, String> {
    if patch["revision"]
        .as_u64()
        .filter(|n| *n > 0 && *n <= 2147483647)
        .is_none()
        || !patch["notes"].is_string()
    {
        return Err("界面资源无效".into());
    }
    let files = patch["resource"]["files"]
        .as_array()
        .ok_or("界面资源无效")?;
    if files.is_empty() || files.len() > 256 {
        return Err("界面资源无效".into());
    }
    let mut result = BTreeMap::new();
    let mut size = 0;
    for file in files {
        let path = file["path"].as_str().ok_or("界面资源路径无效")?;
        let ext = path.rsplit('.').next().unwrap_or("");
        if ![
            "html", "css", "js", "json", "svg", "png", "jpg", "jpeg", "webp", "woff2",
        ]
        .contains(&ext)
            || !path
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_./".contains(&b))
            || path
                .split('/')
                .any(|p| p.is_empty() || p == "." || p == "..")
            || result.contains_key(&format!("/{path}"))
        {
            return Err("界面资源路径无效".into());
        }
        let bytes = STANDARD
            .decode(file["base64"].as_str().ok_or("界面资源编码无效")?)
            .map_err(error)?;
        size += bytes.len();
        if bytes.len() > 2 * 1024 * 1024
            || size > 4 * 1024 * 1024
            || file["sha256"] != format!("{:x}", Sha256::digest(&bytes))
        {
            return Err("界面资源校验失败".into());
        }
        result.insert(format!("/{path}"), bytes);
    }
    for name in REQUIRED {
        if !result.contains_key(&format!("/{name}")) {
            return Err(format!("缺少界面资源 {name}"));
        }
    }
    Ok(result)
}
fn load(dir: &std::path::Path, revision: u32) -> Result<BTreeMap<String, Vec<u8>>, String> {
    let bytes = fs::read(dir.join(format!("{revision}.json"))).map_err(error)?;
    if bytes.len() as u64 > MAX * 2 {
        return Err("界面资源过大".into());
    }
    let payload = verify(
        &serde_json::from_slice(&bytes).map_err(error)?,
        true,
        &super::updates::public_key(),
    )?;
    if payload["patch"]["revision"] != revision {
        return Err("界面资源编号无效".into());
    }
    assets(&payload["patch"])
}
pub fn install(context: &mut tauri::Context<Wry>) -> HotUpdateState {
    let directory =
        root().unwrap_or_else(|_| std::env::temp_dir().join("remotescreen-no-ui-updates"));
    let mut s: Selection = fs::read(directory.join("selection.json"))
        .ok()
        .and_then(|v| serde_json::from_slice(&v).ok())
        .unwrap_or_default();
    let mut rollback = recover(&mut s);
    let files = if s.active > 0 {
        match load(&directory, s.active) {
            Ok(files) => {
                s.booting = s.active;
                files
            }
            Err(_) => {
                s.blocked.push(s.active);
                s.active = 0;
                s.good = 0;
                s.booting = 0;
                rollback = true;
                BTreeMap::new()
            }
        }
    } else {
        BTreeMap::new()
    };
    let running = s.active;
    if save(&directory, &s).is_err() {
        s.active = 0;
        s.booting = 0;
    }
    let bundled = context.set_assets(Box::new(Overlay {
        bundled: None,
        files: BTreeMap::new(),
    }));
    // Development builds use the dev server; only release builds serve the resource overlay.
    let applied = if s.active == running {
        files
    } else {
        BTreeMap::new()
    };
    context.set_assets(Box::new(Overlay {
        bundled: Some(bundled),
        files: applied,
    }));
    HotUpdateState {
        directory,
        selection: Mutex::new(s),
        offered: Mutex::new(None),
        running,
        rollback,
        operation: Mutex::new(()),
    }
}
#[tauri::command]
pub fn hot_update_ready(
    app: tauri::AppHandle,
    window: tauri::WebviewWindow,
) -> Result<Value, String> {
    if window.label() != "main" {
        return Err("更新状态只能由主界面确认".into());
    }
    let state = app.state::<HotUpdateState>();
    let _op = state.operation.lock().unwrap();
    let mut s = state.selection.lock().unwrap();
    s.good = state.running;
    s.booting = 0;
    save(&state.directory, &s)?;
    Ok(json!({"revision":state.running,"rolledBack":state.rollback}))
}
#[tauri::command]
pub async fn hot_update_check(app: tauri::AppHandle) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move||{
  let state=app.state::<HotUpdateState>();let _op=state.operation.lock().unwrap();
  let agent=ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(10)).timeout_read(Duration::from_secs(20)).redirects(0).build();
  let r=agent.get(&format!("{}/v1/hot-updates/check",super::api::SERVER_URL)).query("platform",platform()).query("arch",arch()).query("channel",super::updates::version()["channel"].as_str().unwrap()).query("nativeBuild",&super::updates::version()["buildCode"].to_string()).call().map_err(|_|"暂时无法检查界面更新，请稍后重试")?;
  let mut bytes=Vec::new();r.into_reader().take(MAX*2+1).read_to_end(&mut bytes).map_err(error)?;if bytes.len() as u64>MAX*2{return Err("界面资源过大".into());}
  let envelope:Value=serde_json::from_slice(&bytes).map_err(error)?;let p=verify(&envelope,false,&super::updates::public_key())?;
  let patch=&p["patch"];let revision=patch["revision"].as_u64().unwrap_or(0) as u32;
  let mut s=state.selection.lock().unwrap();
  // Cancel a staged patch if it was withdrawn or superseded before the next launch.
  if s.active!=state.running&&s.active!=revision{s.active=state.running;save(&state.directory,&s)?;}
  // A withdrawn patch may intentionally select an older published revision or the bundled UI.
  let offered=revision!=state.running&&!s.blocked.contains(&revision);
  *state.offered.lock().unwrap()=if offered{Some(envelope)}else{None};
  Ok(json!({"revision":state.running,"staged":s.active!=state.running,"patch":if offered{json!({"revision":revision,"notes":if patch.is_null(){json!("已撤回界面更新，恢复原有界面。")}else{patch["notes"].clone()}})}else{Value::Null}}))
 }).await.map_err(error)?
}
#[tauri::command]
pub fn hot_update_stage(app: tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<HotUpdateState>();
    let _op = state.operation.lock().unwrap();
    let envelope = state
        .offered
        .lock()
        .unwrap()
        .clone()
        .ok_or("请先检查界面更新")?;
    let p = verify(&envelope, false, &super::updates::public_key())?;
    let revision = p["patch"]["revision"].as_u64().unwrap_or(0) as u32;
    if revision > 0 {
        atomic_write(
            &state.directory,
            &format!("{revision}.json"),
            &serde_json::to_vec(&envelope).map_err(error)?,
        )?;
    }
    let mut s = state.selection.lock().unwrap();
    s.active = revision;
    save(&state.directory, &s)
}
#[tauri::command]
pub fn hot_update_restart(app: tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<super::AppState>();
    if state.friend.lock().unwrap().is_some()
        || state.session.lock().unwrap().is_some()
        || state.watch.lock().unwrap().is_some()
        || state.file_session.lock().unwrap().is_some()
        || state.file_host.lock().unwrap().is_some()
        || state.pending_request.lock().unwrap().is_some()
    {
        return Err("请先结束通话、投屏和文件传输，再重新打开应用以应用更新".into());
    }
    app.restart()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};
    fn patch() -> Value {
        json!({"revision":1,"notes":"更新","resource":{"files":REQUIRED.iter().map(|name|json!({"path":name,"base64":STANDARD.encode(name.as_bytes()),"sha256":format!("{:x}",Sha256::digest(name.as_bytes()))})).collect::<Vec<_>>()}})
    }
    fn sign(p: &Value) -> (Value, Value) {
        let pair = Ed25519KeyPair::from_seed_unchecked(&[8; 32]).unwrap();
        let bytes = serde_json::to_vec(p).unwrap();
        (
            json!({"algorithm":"ed25519","keyId":"test","payload":STANDARD.encode(&bytes),"signature":STANDARD.encode(pair.sign(&bytes).as_ref())}),
            json!({"keyId":"test","publicKey":STANDARD.encode(pair.public_key().as_ref())}),
        )
    }
    fn payload() -> Value {
        json!({"schema":1,"kind":"hot-update","target":{"platform":platform(),"arch":arch(),"channel":"stable","nativeBuild":super::super::updates::version()["buildCode"]},"checkedAt":now(),"expiresAt":now()+900000,"patch":patch()})
    }
    #[test]
    fn signed_assets_reject_tampering_wrong_build_and_expiry() {
        let p = payload();
        let (mut e, k) = sign(&p);
        assert!(verify(&e, false, &k).is_ok());
        e["payload"] = json!(STANDARD.encode(b"changed"));
        assert!(verify(&e, false, &k).is_err());
        let mut p = payload();
        p["target"]["nativeBuild"] = json!(1);
        let (e, k) = sign(&p);
        assert!(verify(&e, false, &k).is_err());
        let mut p = payload();
        p["expiresAt"] = json!(1);
        let (e, k) = sign(&p);
        assert!(verify(&e, false, &k).is_err());
        assert!(verify(&e, true, &k).is_ok());
    }
    #[test]
    fn resource_paths_and_hashes_are_validated_before_loading() {
        let p = patch();
        let map = assets(&p).unwrap();
        let overlay = Overlay {
            bundled: None,
            files: map,
        };
        assert_eq!(
            overlay.get(&AssetKey::from("style.css")).unwrap().as_ref(),
            b"style.css"
        );
        let mut p = patch();
        p["resource"]["files"][0]["path"] = json!("../index.html");
        assert!(assets(&p).is_err());
        let mut p = patch();
        p["resource"]["files"][0]["sha256"] = json!("0".repeat(64));
        assert!(assets(&p).is_err());
        let mut p = patch();
        p["resource"]["files"] = json!([]);
        assert!(assets(&p).is_err());
    }
    #[test]
    fn unsuccessful_start_recovers_previous_good_or_bundled_resources() {
        let mut s = Selection {
            active: 2,
            good: 1,
            booting: 2,
            blocked: vec![],
        };
        assert!(recover(&mut s));
        assert_eq!(s.active, 1);
        assert_eq!(s.blocked, vec![2]);
        assert!(!recover(&mut s));
        s.booting = 1;
        assert!(recover(&mut s));
        assert_eq!(s.active, 0);
        assert_eq!(s.good, 0);
    }
}
