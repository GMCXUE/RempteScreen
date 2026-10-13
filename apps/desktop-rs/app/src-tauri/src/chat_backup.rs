use super::chat_store::{hash, number, string, Result, Store};
use base64::{engine::general_purpose::STANDARD, Engine};
use ring::{
    aead, pbkdf2,
    rand::{SecureRandom, SystemRandom},
};
use rusqlite::OptionalExtension;
use serde_json::{json, Value};
use std::{
    fs::{File, OpenOptions},
    io::{BufRead, BufReader, Write},
    num::NonZeroU32,
    path::Path,
};
const CHUNK: usize = 256 * 1024;
fn key(password: &str, salt: &[u8]) -> Result<aead::LessSafeKey> {
    if password.chars().count() < 8 {
        return Err("备份密码至少需要 8 个字符".into());
    }
    let mut key = [0; 32];
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA256,
        NonZeroU32::new(210000).unwrap(),
        salt,
        password.as_bytes(),
        &mut key,
    );
    Ok(aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::AES_256_GCM, &key).map_err(|_| "无法创建备份密钥")?,
    ))
}
fn nonce(n: u64) -> aead::Nonce {
    let mut bytes = [0; 12];
    bytes[4..].copy_from_slice(&n.to_be_bytes());
    aead::Nonce::assume_unique_for_key(bytes)
}
fn line(reader: &mut impl BufRead) -> Result<Option<String>> {
    let mut bytes = vec![];
    loop {
        let buf = reader.fill_buf()?;
        if buf.is_empty() {
            return if bytes.is_empty() {
                Ok(None)
            } else {
                Err("备份文件不完整".into())
            };
        }
        let end = buf.iter().position(|b| *b == b'\n');
        let count = end.map_or(buf.len(), |i| i + 1);
        if bytes.len() + count > 1024 * 1024 + 1 {
            return Err("备份文件记录过大".into());
        }
        bytes.extend_from_slice(&buf[..count]);
        reader.consume(count);
        if end.is_some() {
            bytes.pop();
            return Ok(Some(String::from_utf8(bytes)?));
        }
    }
}
struct Writer {
    file: File,
    key: aead::LessSafeKey,
    header: String,
    n: u64,
}
impl Writer {
    fn record(&mut self, record: Value) -> Result<()> {
        let mut bytes = serde_json::to_vec(&record)?;
        let aad = format!("{}:{}", self.header, self.n);
        self.key
            .seal_in_place_append_tag(nonce(self.n), aead::Aad::from(aad.as_bytes()), &mut bytes)
            .map_err(|_| "备份加密失败")?;
        writeln!(self.file, "{}", STANDARD.encode(bytes))?;
        self.n += 1;
        Ok(())
    }
}
pub fn export_file(s: &Store, owner: &str, path: &Path, password: &str) -> Result<()> {
    let mut salt = [0; 16];
    SystemRandom::new()
        .fill(&mut salt)
        .map_err(|_| "无法创建备份随机数")?;
    let header =
        json!({"format":"RemoteScreenChat","version":1,"salt":STANDARD.encode(salt)}).to_string();
    let key = key(password, &salt)?;
    let part = path.with_extension(format!("{}.part", hash(&salt)));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut writer = Writer {
        file: options.open(&part)?,
        key,
        header,
        n: 0,
    };
    let result = (|| -> Result<()> {
        writeln!(writer.file, "{}", writer.header)?;
        s.snapshot(||{
   writer.record(json!({"type":"owner","id":owner}))?;
   if let Some(state)=s.setting(owner,"state")?{writer.record(json!({"type":"state","data":serde_json::from_str::<Value>(&state)?}))?;}
   let mut stmt=s.0.prepare("SELECT key,data FROM settings WHERE owner=? AND key LIKE 'clear:%'")?;
   for row in stmt.query_map([owner],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))? {let (key,seq)=row?;writer.record(json!({"type":"clear","peer":&key[6..],"seq":seq}))?;}
   drop(stmt);let mut after=0;
   loop {let rows=s.rows("SELECT row FROM messages WHERE owner=? AND seq>? ORDER BY seq LIMIT 100",vec![owner.to_owned().into(),after.into()])?;if rows.is_empty(){break;}
    for row in rows{let id=string(&row,"id")?;after=number(&row,"seq")?;let peer:String=s.0.query_row("SELECT peer FROM messages WHERE owner=? AND id=?",rusqlite::params![owner,id],|r|r.get(0))?;
     writer.record(json!({"type":"message","peer":peer,"row":row}))?;
     let media=s.0.query_row("SELECT data,mime,sha FROM media WHERE owner=? AND id=?",rusqlite::params![owner,id],|r|Ok((r.get::<_,Vec<u8>>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))).optional()?;
     if let Some((bytes,mime,sha))=media{
      if hash(&bytes)!=sha{return Err("本地媒体校验失败，请重新下载后备份".into());}
      writer.record(json!({"type":"media-start","id":id,"mime":mime,"sha":hash(&bytes),"bytes":bytes.len()}))?;
      for chunk in bytes.chunks(CHUNK){writer.record(json!({"type":"media-chunk","data":STANDARD.encode(chunk)}))?;}
      writer.record(json!({"type":"media-end"}))?;
     }
    }
   }writer.record(json!({"type":"end","records":writer.n}))?;Ok(())
  })?;
        writer.file.sync_all()?;
        Ok(())
    })();
    drop(writer);
    if let Err(e) = result {
        let _ = std::fs::remove_file(&part);
        return Err(e);
    }
    if let Err(e) = std::fs::rename(&part, path) {
        let _ = std::fs::remove_file(&part);
        return Err(e.into());
    }
    Ok(())
}
pub fn restore_file(s: &Store, owner: &str, path: &Path, password: &str) -> Result<usize> {
    let mut reader = BufReader::new(File::open(path)?);
    let header = line(&mut reader)?.ok_or("备份文件为空")?;
    if header.len() > 4096 {
        return Err("备份文件格式不正确".into());
    }
    let info: Value = serde_json::from_str(&header)?;
    if info["format"] != "RemoteScreenChat" || info["version"] != 1 {
        return Err("不支持的备份格式".into());
    }
    let salt = STANDARD.decode(string(&info, "salt")?)?;
    if salt.len() != 16 {
        return Err("备份文件格式不正确".into());
    }
    let key = key(password, &salt)?;
    s.transaction(|| {
        let mut n = 0;
        let mut ended = false;
        let mut owner_checked = false;
        let mut count = 0;
        let mut media: Option<Value> = None;
        let mut bytes = vec![];
        while let Some(encoded) = line(&mut reader)? {
            if ended {
                return Err("备份文件包含多余数据".into());
            }
            let mut encrypted = STANDARD.decode(encoded)?;
            let aad = format!("{header}:{n}");
            let plain = key
                .open_in_place(nonce(n), aead::Aad::from(aad.as_bytes()), &mut encrypted)
                .map_err(|_| "备份密码错误或文件已损坏")?;
            let row: Value = serde_json::from_slice(plain)?;
            let kind = string(&row, "type")?;
            if n == 0 {
                if kind != "owner" || row["id"] != owner {
                    return Err("请登录备份所属账号后再恢复".into());
                }
                owner_checked = true;
            } else {
                if media.is_some() && kind != "media-chunk" && kind != "media-end" {
                    return Err("备份媒体不完整".into());
                }
                match kind {
                    "state" => {
                        if row["data"]["me"]["id"] != owner {
                            return Err("备份账号无效".into());
                        }
                        if s.setting(owner, "state")?.is_none() {
                            s.set(owner, "state", &row["data"].to_string())?;
                        }
                    }
                    "clear" => s.clear(owner, string(&row, "peer")?, number(&row, "seq")?)?,
                    "message" => {
                        s.merge(owner, string(&row, "peer")?, &row["row"])?;
                        count += 1;
                    }
                    "media-start" => {
                        let size = number(&row, "bytes")?;
                        if !(1..=50 * 1024 * 1024).contains(&size)
                            || !["image/jpeg", "video/mp4"].contains(&string(&row, "mime")?)
                        {
                            return Err("备份媒体格式不正确".into());
                        }
                        media = Some(row);
                        bytes.clear();
                    }
                    "media-chunk" => {
                        let m = media.as_ref().ok_or("备份媒体格式不正确")?;
                        let chunk = STANDARD.decode(string(&row, "data")?)?;
                        if chunk.len() > CHUNK
                            || bytes.len() + chunk.len() > number(m, "bytes")? as usize
                        {
                            return Err("备份媒体大小不正确".into());
                        }
                        bytes.extend(chunk);
                    }
                    "media-end" => {
                        let m = media.take().ok_or("备份媒体格式不正确")?;
                        if bytes.len() != number(&m, "bytes")? as usize {
                            return Err("备份媒体不完整".into());
                        }
                        s.save_bytes(
                            owner,
                            string(&m, "id")?,
                            &bytes,
                            string(&m, "mime")?,
                            Some(string(&m, "sha")?),
                        )?;
                        bytes.clear();
                    }
                    "end" => {
                        if number(&row, "records")? != n as i64 {
                            return Err("备份文件不完整".into());
                        }
                        ended = true;
                    }
                    _ => return Err("不支持的备份记录".into()),
                }
            }
            n += 1;
        }
        if !ended || !owner_checked || media.is_some() {
            return Err("备份文件不完整".into());
        }
        Ok(count)
    })
}
#[tauri::command]
pub async fn chat_archive(
    app: tauri::AppHandle,
    action: String,
    password: Option<String>,
) -> std::result::Result<Value, String> {
    let token = super::chat_media::token(&app)?;
    let path = if action == "export" {
        rfd::AsyncFileDialog::new()
            .set_file_name("RemoteScreen聊天备份.rschat")
            .save_file()
            .await
    } else if action == "import" {
        rfd::AsyncFileDialog::new()
            .add_filter("聊天备份", &["rschat"])
            .pick_file()
            .await
    } else {
        None
    };
    if ["export", "import"].contains(&action.as_str()) && path.is_none() {
        return Ok(json!({"cancelled":true}));
    }
    if super::chat_media::token(&app)? != token {
        return Err("账号已变化，请重新打开聊天记录设置".into());
    }
    tauri::async_runtime::spawn_blocking(move||->Result<Value>{
  let s=Store::open()?;let owner=s.owner(&token)?;
  if action=="export"{let path=path.ok_or("备份路径无效")?;export_file(&s,&owner,path.path(),password.as_deref().unwrap_or(""))?;return Ok(json!({"message":"备份已保存，可复制到其他设备后恢复"}));}
  if action=="import"{let path=path.ok_or("备份路径无效")?;let count=restore_file(&s,&owner,path.path(),password.as_deref().unwrap_or(""))?;return Ok(json!({"message":format!("恢复完成，已合并 {count} 条记录") }));}
  if action=="sync"{super::chat_store::sync_now(&token)?;}
  let messages:i64=s.0.query_row("SELECT COUNT(*) FROM messages WHERE owner=?",[&owner],|r|r.get(0))?;
  let missing:i64=s.0.query_row("SELECT COUNT(*) FROM messages m WHERE owner=? AND kind IN ('image','video') AND NOT EXISTS(SELECT 1 FROM media b WHERE b.owner=m.owner AND b.id=m.id)",[&owner],|r|r.get(0))?;
  Ok(json!({"messages":messages,"missing":missing,"error":s.setting(&owner,"sync_error")?,"retentionDays":7}))
 }).await.map_err(|e|e.to_string())?.map_err(|e|super::chat_store::display_error(e.as_ref()))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "rs-chat-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&path).unwrap();
        path
    }
    fn row(id: &str, seq: u64, kind: &str) -> Value {
        json!({"id":id,"seq":seq.to_string(),"senderId":"alice","clientId":format!("client_{id}"),"kind":kind,"text":"中文 %_ ","createdAt":"1720000000000","editSeq":"0"})
    }
    #[test]
    fn transactional_backup_and_local_history() {
        let root = root();
        let a = Store::at(root.join("a.db")).unwrap();
        let b = Store::at(root.join("b.db")).unwrap();
        a.transaction(|| {
            a.merge("alice", "bob", &row("text", 1, "text"))?;
            a.merge("alice", "bob", &row("video", 2, "video"))?;
            a.save_bytes("alice", "video", &vec![42; CHUNK + 33], "video/mp4", None)?;
            Ok(())
        })
        .unwrap();
        let archive = root.join("backup.rschat");
        export_file(&a, "alice", &archive, "synthetic-password").unwrap();
        assert_eq!(
            restore_file(&b, "alice", &archive, "synthetic-password").unwrap(),
            2
        );
        assert_eq!(
            restore_file(&b, "alice", &archive, "synthetic-password").unwrap(),
            2
        );
        assert_eq!(
            b.query("alice", "history", &json!({"peerId":"bob"}))
                .unwrap()["messages"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert!(b
            .query("bob", "history", &json!({"peerId":"alice"}))
            .unwrap()["messages"]
            .as_array()
            .unwrap()
            .is_empty());
        assert_eq!(
            b.bytes("alice", "video").unwrap().unwrap(),
            vec![42; CHUNK + 33]
        );
        assert!(restore_file(&b, "alice", &archive, "wrong-password").is_err());
        assert!(restore_file(&b, "bob", &archive, "synthetic-password").is_err());
        let mut recalled = row("video", 2, "recalled");
        recalled["editSeq"] = json!("9");
        b.merge("alice", "bob", &recalled).unwrap();
        restore_file(&b, "alice", &archive, "synthetic-password").unwrap();
        assert_eq!(
            b.message("alice", "video").unwrap().unwrap()["kind"],
            "recalled"
        );
        assert_eq!(
            b.message("alice", "video").unwrap().unwrap()["editSeq"],
            "9"
        );
        assert!(b.bytes("alice", "video").unwrap().is_none());
        b.transaction(|| b.clear("alice", "bob", 2)).unwrap();
        restore_file(&b, "alice", &archive, "synthetic-password").unwrap();
        assert!(b.message("alice", "text").unwrap().is_none());
        let mut lines = std::fs::read_to_string(&archive)
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        lines.pop();
        let broken = root.join("truncated.rschat");
        std::fs::write(&broken, lines.join("\n") + "\n").unwrap();
        let empty = Store::at(root.join("empty.db")).unwrap();
        assert!(restore_file(&empty, "alice", &broken, "synthetic-password").is_err());
        assert!(empty.message("alice", "text").unwrap().is_none());
        drop(a);
        let reopened = Store::at(root.join("a.db")).unwrap();
        assert!(reopened.message("alice", "text").unwrap().is_some());
        drop(reopened);
        drop(b);
        drop(empty);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn cross_platform_fixture() {
        let Ok(root) = std::env::var("RS_CHAT_CROSS_DIR") else {
            return;
        };
        let root = std::path::PathBuf::from(root);
        std::fs::create_dir_all(&root).unwrap();
        let s = Store::at(root.join("rust.db")).unwrap();
        s.merge("cross-account","peer",&json!({"id":"cross-text","seq":"1","senderId":"cross-account","kind":"text","text":"两端互通 %_","createdAt":"1720000000000","editSeq":"0"})).unwrap();
        s.merge("cross-account","peer",&json!({"id":"cross-media","seq":"2","senderId":"peer","kind":"video","text":"[视频]","video":{"bytes":CHUNK+13,"sha256":hash(&vec![7;CHUNK+13])},"createdAt":"1720000000001","editSeq":"0"})).unwrap();
        s.save_bytes(
            "cross-account",
            "cross-media",
            &vec![7; CHUNK + 13],
            "video/mp4",
            None,
        )
        .unwrap();
        export_file(
            &s,
            "cross-account",
            &root.join("rust.rschat"),
            "cross-password",
        )
        .unwrap();
        if root.join("dart.rschat").exists() {
            let target = Store::at(root.join("from-dart.db")).unwrap();
            assert_eq!(
                restore_file(
                    &target,
                    "cross-account",
                    &root.join("dart.rschat"),
                    "cross-password"
                )
                .unwrap(),
                2
            );
            assert_eq!(
                target
                    .bytes("cross-account", "cross-media")
                    .unwrap()
                    .unwrap(),
                vec![7; CHUNK + 13]
            );
        }
    }
}
