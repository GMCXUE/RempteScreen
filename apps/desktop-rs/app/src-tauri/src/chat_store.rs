use base64::{engine::general_purpose::STANDARD, Engine};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    io::Read,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
pub struct Store(pub Connection);
static MEDIA_BUSY: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);
pub fn reset_media_busy() {
    MEDIA_BUSY.store(0, std::sync::atomic::Ordering::Relaxed);
}
pub fn set_screen_busy(busy: bool) {
    if busy {
        MEDIA_BUSY.fetch_or(1, std::sync::atomic::Ordering::Relaxed);
    } else {
        MEDIA_BUSY.fetch_and(!1, std::sync::atomic::Ordering::Relaxed);
    }
}
fn media_blocked() -> bool {
    MEDIA_BUSY.load(std::sync::atomic::Ordering::Relaxed) != 0
}

impl Store {
    pub fn open() -> Result<Self> {
        let root = dirs::data_local_dir()
            .ok_or("无法打开本地聊天目录")?
            .join("RemoteScreen");
        std::fs::create_dir_all(&root)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))?;
        }
        Self::at(root.join("chat-v1.sqlite"))
    }
    pub fn at(path: PathBuf) -> Result<Self> {
        let db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(30))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;
   CREATE TABLE IF NOT EXISTS bindings(token TEXT PRIMARY KEY,owner TEXT NOT NULL);
   CREATE TABLE IF NOT EXISTS settings(owner TEXT NOT NULL,key TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(owner,key));
   CREATE TABLE IF NOT EXISTS messages(owner TEXT NOT NULL,id TEXT NOT NULL,peer TEXT NOT NULL,seq INTEGER NOT NULL,kind TEXT NOT NULL,text TEXT NOT NULL,created INTEGER NOT NULL,edit INTEGER NOT NULL,row TEXT NOT NULL,acked INTEGER NOT NULL DEFAULT 0,sender TEXT NOT NULL,PRIMARY KEY(owner,id));
   CREATE INDEX IF NOT EXISTS chat_pair ON messages(owner,peer,seq);
   CREATE UNIQUE INDEX IF NOT EXISTS chat_sequence ON messages(owner,seq);
   CREATE TABLE IF NOT EXISTS media(owner TEXT NOT NULL,id TEXT NOT NULL,data BLOB NOT NULL,sha TEXT NOT NULL,mime TEXT NOT NULL,PRIMARY KEY(owner,id),FOREIGN KEY(owner,id) REFERENCES messages(owner,id) ON DELETE CASCADE);")?;
        let has_sender = {
            let mut stmt = db.prepare("PRAGMA table_info(messages)")?;
            let names = stmt
                .query_map([], |r| r.get::<_, String>(1))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            names.iter().any(|n| n == "sender")
        };
        if !has_sender {
            db.execute_batch("ALTER TABLE messages ADD COLUMN sender TEXT NOT NULL DEFAULT ''; UPDATE messages SET sender=json_extract(row,'$.senderId');")?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(
                db.path().ok_or("本地聊天路径无效")?,
                std::fs::Permissions::from_mode(0o600),
            )?;
        }
        Ok(Self(db))
    }
    pub fn setting(&self, owner: &str, key: &str) -> Result<Option<String>> {
        Ok(self
            .0
            .query_row(
                "SELECT data FROM settings WHERE owner=? AND key=?",
                params![owner, key],
                |r| r.get(0),
            )
            .optional()?)
    }
    pub fn set(&self, owner: &str, key: &str, data: &str) -> Result<()> {
        if (["after", "edit"].contains(&key) || key.starts_with("read:")) {
            if self
                .setting(owner, key)?
                .unwrap_or_else(|| "0".into())
                .parse::<i64>()?
                > data.parse::<i64>()?
            {
                return Ok(());
            }
        }
        self.0.execute(
            "INSERT OR REPLACE INTO settings VALUES(?,?,?)",
            params![owner, key, data],
        )?;
        Ok(())
    }
    pub fn bind(&self, token: &str, owner: &str) -> Result<()> {
        self.0.execute(
            "INSERT OR REPLACE INTO bindings VALUES(?,?)",
            params![hash(token.as_bytes()), owner],
        )?;
        Ok(())
    }
    pub fn owner(&self, token: &str) -> Result<String> {
        if let Some(owner) = self
            .0
            .query_row(
                "SELECT owner FROM bindings WHERE token=?",
                [hash(token.as_bytes())],
                |r| r.get::<_, String>(0),
            )
            .optional()?
        {
            return Ok(owner);
        }
        let state = super::api::social_remote("state", token, json!({}))?;
        let id = state["me"]["id"].as_str().ok_or("账号无效")?;
        self.bind(token, id)?;
        self.set(id, "state", &state.to_string())?;
        Ok(id.into())
    }
    pub fn clear(&self, owner: &str, peer: &str, seq: i64) -> Result<()> {
        let key = format!("clear:{peer}");
        let old = self
            .setting(owner, &key)?
            .unwrap_or_else(|| "0".into())
            .parse::<i64>()?;
        if seq > old {
            self.set(owner, &key, &seq.to_string())?;
            self.0.execute(
                "DELETE FROM messages WHERE owner=? AND peer=? AND seq<=?",
                params![owner, peer, seq],
            )?;
        }
        Ok(())
    }
    pub fn merge(&self, owner: &str, peer: &str, row: &Value) -> Result<()> {
        let id = string(row, "id")?;
        let kind = string(row, "kind")?;
        let seq = number(row, "seq")?;
        let created = number(row, "createdAt")?;
        let sender = string(row, "senderId")?;
        if id.is_empty()
            || id.len() > 100
            || peer.is_empty()
            || peer.len() > 100
            || peer == owner
            || seq < 1
            || ![owner, peer].contains(&sender)
            || !["text", "image", "video", "call", "recalled"].contains(&kind)
        {
            return Err("聊天记录格式不正确".into());
        }
        if seq
            <= self
                .setting(owner, &format!("clear:{peer}"))?
                .unwrap_or_else(|| "0".into())
                .parse::<i64>()?
        {
            return Ok(());
        }
        if let Some(existing) = self.message(owner, id)? {
            let old_peer: String = self.0.query_row(
                "SELECT peer FROM messages WHERE owner=? AND id=?",
                params![owner, id],
                |r| r.get(0),
            )?;
            if old_peer != peer
                || number(&existing, "seq")? != seq
                || existing["senderId"] != row["senderId"]
            {
                return Err("聊天记录身份不一致".into());
            }
        }
        let edit = if row["editSeq"].is_null() {
            0
        } else {
            number(row, "editSeq")?
        };
        if edit < 0 || created < 0 || created > 8640000000000000 || !row["text"].is_string() {
            return Err("聊天记录格式不正确".into());
        }
        let mut canonical = row.clone();
        canonical["seq"] = json!(seq.to_string());
        canonical["createdAt"] = json!(created.to_string());
        canonical["editSeq"] = json!(edit.to_string());
        self.0.execute("INSERT INTO messages(owner,id,peer,seq,kind,text,created,edit,row,sender) VALUES(?,?,?,?,?,?,?,?,?,?)
   ON CONFLICT(owner,id) DO UPDATE SET kind=excluded.kind,text=excluded.text,edit=excluded.edit,row=excluded.row,acked=0
   WHERE (excluded.edit>=messages.edit OR (excluded.kind='recalled' AND messages.kind<>'recalled')) AND (messages.kind<>'recalled' OR excluded.kind='recalled')",
   params![owner,id,peer,seq,kind,row["text"].as_str().unwrap_or(""),created,edit,canonical.to_string(),sender])?;
        if kind == "recalled" {
            self.0.execute(
                "DELETE FROM media WHERE owner=? AND id=?",
                params![owner, id],
            )?;
        }
        Ok(())
    }
    pub fn message(&self, owner: &str, id: &str) -> Result<Option<Value>> {
        let row = self
            .0
            .query_row(
                "SELECT row FROM messages WHERE owner=? AND id=?",
                params![owner, id],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(row.map(|s| serde_json::from_str(&s)).transpose()?)
    }
    pub fn bytes(&self, owner: &str, id: &str) -> Result<Option<Vec<u8>>> {
        let row = self
            .0
            .query_row(
                "SELECT data,sha FROM media WHERE owner=? AND id=?",
                params![owner, id],
                |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        if let Some((data, sha)) = row {
            if hash(&data) == sha {
                return Ok(Some(data));
            }
            self.0.execute(
                "DELETE FROM media WHERE owner=? AND id=?",
                params![owner, id],
            )?;
        }
        Ok(None)
    }
    pub fn save_bytes(
        &self,
        owner: &str,
        id: &str,
        data: &[u8],
        mime: &str,
        expected: Option<&str>,
    ) -> Result<()> {
        if self.0.is_autocommit() {
            return self.transaction(|| self.save_bytes(owner, id, data, mime, expected));
        }
        let Some(row) = self.message(owner, id)? else {
            return Ok(());
        };
        if row["kind"] == "recalled" {
            return Ok(());
        }
        if data.is_empty()
            || data.len() > 50 * 1024 * 1024
            || expected.is_some_and(|s| s != hash(data))
        {
            return Err("媒体校验失败".into());
        }
        let kind = row["kind"].as_str().unwrap_or("");
        if let Some(size) = row[kind]["bytes"].as_i64() {
            if data.len() as i64 != size {
                return Err("媒体大小校验失败".into());
            }
        }
        self.0.execute(
            "INSERT OR REPLACE INTO media VALUES(?,?,?,?,?)",
            params![owner, id, data, hash(data), mime],
        )?;
        Ok(())
    }
    pub fn snapshot<T>(&self, action: impl FnOnce() -> Result<T>) -> Result<T> {
        self.0.execute_batch("BEGIN")?;
        match action() {
            Ok(v) => {
                self.0.execute_batch("COMMIT")?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.0.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }
    pub fn transaction<T>(&self, action: impl FnOnce() -> Result<T>) -> Result<T> {
        self.0.execute_batch("BEGIN IMMEDIATE")?;
        match action() {
            Ok(v) => {
                self.0.execute_batch("COMMIT")?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.0.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }
    pub fn apply(&self, owner: &str, feed: &Value) -> Result<()> {
        self.transaction(|| {
            for r in feed["reads"].as_array().unwrap_or(&vec![]) {
                self.set(
                    owner,
                    &format!("read:{}", string(r, "peerId")?),
                    string(r, "seq")?,
                )?;
            }
            for c in feed["clears"].as_array().ok_or("同步格式不正确")? {
                self.clear(owner, string(c, "peerId")?, number(c, "seq")?)?;
            }
            for row in feed["messages"]
                .as_array()
                .ok_or("同步格式不正确")?
                .iter()
                .chain(feed["updates"].as_array().ok_or("同步格式不正确")?)
            {
                self.merge(owner, string(row, "peerId")?, row)?;
            }
            self.set(owner, "after", string(feed, "after")?)?;
            self.set(owner, "edit", string(feed, "edit")?)?;
            Ok(())
        })
    }
    pub fn rows(&self, sql: &str, args: Vec<rusqlite::types::Value>) -> Result<Vec<Value>> {
        let mut stmt = self.0.prepare(sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(args), |r| r.get::<_, String>(0))?;
        let mut result = vec![];
        for row in rows {
            result.push(serde_json::from_str(&row?)?);
        }
        Ok(result)
    }
    pub fn decorate(&self, owner: &str, mut state: Value) -> Result<Value> {
        let offline = state["offline"] == true;
        if let Some(friends) = state["friends"].as_array_mut() {
            for friend in friends {
                let peer = string(friend, "id")?.to_owned();
                let rows = self.rows(
                    "SELECT row FROM messages WHERE owner=? AND peer=? ORDER BY seq DESC LIMIT 1",
                    vec![owner.to_owned().into(), peer.clone().into()],
                )?;
                if let Some(row) = rows.first() {
                    friend["lastText"] = row["text"].clone();
                }
                let read = self
                    .setting(owner, &format!("read:{peer}"))?
                    .unwrap_or_else(|| "0".into())
                    .parse::<i64>()?;
                let count:i64=self.0.query_row("SELECT COUNT(*) FROM messages WHERE owner=? AND peer=? AND seq>? AND kind<>'recalled' AND sender=?",params![owner,peer,read,peer],|r|r.get(0))?;
                friend["unread"] = json!(if offline {
                    count
                } else {
                    count.max(friend["unread"].as_i64().unwrap_or(0))
                });
            }
        }
        Ok(state)
    }
    pub fn query(&self, owner: &str, op: &str, body: &Value) -> Result<Value> {
        use rusqlite::types::Value as Sql;
        let peer = string(body, "peerId")?;
        let boundary = self
            .setting(owner, &format!("clear:{peer}"))?
            .unwrap_or_else(|| "0".into());
        let mut meta =
            json!({"clearedThrough":boundary,"syncCursor":"0","serverNow":now().to_string()});
        if op == "message-context" {
            let row = self
                .message(owner, string(body, "messageId")?)?
                .ok_or("消息已清空或不存在")?;
            let seq = number(&row, "seq")?;
            let args = vec![
                Sql::Text(owner.into()),
                Sql::Text(peer.into()),
                Sql::Integer(seq),
            ];
            let lower=self.rows("SELECT row FROM messages WHERE owner=? AND peer=? AND seq<=? ORDER BY seq DESC LIMIT 26",args.clone())?;
            let upper = self.rows(
                "SELECT row FROM messages WHERE owner=? AND peer=? AND seq>? ORDER BY seq LIMIT 26",
                args,
            )?;
            meta["hasMore"] = json!(lower.len() > 25);
            meta["hasNewer"] = json!(upper.len() > 25);
            meta["messages"] = json!(lower
                .into_iter()
                .take(25)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .chain(upper.into_iter().take(25))
                .collect::<Vec<_>>());
            return Ok(meta);
        }
        let mut where_sql = "owner=? AND peer=?".to_owned();
        let mut args = vec![Sql::Text(owner.into()), Sql::Text(peer.into())];
        for (key, symbol) in [("before", "<"), ("after", ">")] {
            if !body[key].is_null() {
                where_sql += &format!(" AND seq{symbol}?");
                args.push(Sql::Integer(number(body, key)?));
            }
        }
        if op == "history" {
            where_sql += " AND kind<>'recalled'";
            let kind = body["kind"].as_str().unwrap_or("all");
            match kind {
                "all" => {}
                "media" => where_sql += " AND kind IN ('image','video')",
                "link" => {
                    where_sql +=
                        " AND kind='text' AND (text LIKE '%http://%' OR text LIKE '%https://%')"
                }
                _ => {
                    where_sql += " AND kind=?";
                    args.push(Sql::Text(kind.into()));
                }
            }
            let q = body["query"].as_str().unwrap_or("").trim();
            if !q.is_empty() {
                where_sql += " AND text LIKE ? ESCAPE '\\'";
                args.push(Sql::Text(format!(
                    "%{}%",
                    q.replace('\\', "\\\\")
                        .replace('%', "\\%")
                        .replace('_', "\\_")
                )));
            }
            for (key, symbol) in [("from", ">="), ("to", "<")] {
                if !body[key].is_null() {
                    where_sql += &format!(" AND created{symbol}?");
                    args.push(Sql::Integer(number(body, key)?));
                }
            }
        }
        let asc = op == "messages" && !body["after"].is_null();
        let order = if asc { "ASC" } else { "DESC" };
        let rows = self.rows(
            &format!("SELECT row FROM messages WHERE {where_sql} ORDER BY seq {order} LIMIT 51"),
            args,
        )?;
        meta["hasMore"] = json!(rows.len() > 50);
        let mut selected = rows.into_iter().take(50).collect::<Vec<_>>();
        if op == "messages" && !asc {
            selected.reverse();
        }
        meta["messages"] = json!(selected);
        meta["updates"] = if op == "messages" {
            json!(self.rows(
                "SELECT row FROM messages WHERE owner=? AND peer=? AND kind='recalled'",
                vec![Sql::Text(owner.into()), Sql::Text(peer.into())]
            )?)
        } else {
            json!([])
        };
        Ok(meta)
    }
}
pub fn hash(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
pub fn string<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str().ok_or_else(|| "聊天记录格式不正确".into())
}
pub fn number(v: &Value, k: &str) -> Result<i64> {
    if let Some(n) = v[k].as_i64() {
        return Ok(n);
    }
    Ok(string(v, k)?.parse()?)
}
fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn sync_feed(token: &str) -> Result<()> {
    let s = Store::open()?;
    let owner = s.owner(token)?;
    super::api::social_remote("local-activate", token, json!({}))?;
    loop {
        let feed = super::api::social_remote(
            "local-feed",
            token,
            json!({"after":s.setting(&owner,"after")?.unwrap_or_else(||"0".into()),"edit":s.setting(&owner,"edit")?.unwrap_or_else(||"0".into())}),
        )?;
        s.apply(&owner, &feed)?;
        if feed["hasMore"] != true {
            break;
        }
    }
    Ok(())
}
fn acknowledge(s: &Store, owner: &str, token: &str) -> Result<()> {
    loop {
        let mut stmt=s.0.prepare("SELECT id FROM messages m WHERE owner=? AND acked=0 AND (kind NOT IN ('image','video') OR EXISTS(SELECT 1 FROM media b WHERE b.owner=m.owner AND b.id=m.id)) LIMIT 100")?;
        let ids = stmt
            .query_map([owner], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        if ids.is_empty() {
            break;
        }
        if !ids.is_empty() {
            super::api::social_remote("local-saved", token, json!({"ids":ids}))?;
            s.transaction(|| {
                for id in ids {
                    s.0.execute(
                        "UPDATE messages SET acked=1 WHERE owner=? AND id=?",
                        params![owner, id],
                    )?;
                }
                Ok(())
            })?;
        }
    }
    Ok(())
}
pub fn download_video(token: &str, peer: &str, id: &str, row: &Value) -> Result<Vec<u8>> {
    download_video_policy(token, peer, id, row, false)
}
fn download_video_policy(
    token: &str,
    peer: &str,
    id: &str,
    row: &Value,
    background: bool,
) -> Result<Vec<u8>> {
    let meta = &row["video"];
    let size = number(meta, "bytes")?;
    if !(1..=50 * 1024 * 1024).contains(&size) {
        return Err("视频信息无效".into());
    }
    let r = ureq::get(&format!("{}/v1/social/videos/{id}", super::api::SERVER_URL))
        .query("peerId", peer)
        .query("archive", "1")
        .set("Authorization", &format!("Bearer {token}"))
        .timeout(std::time::Duration::from_secs(120))
        .call()
        .map_err(|_| "视频未下载或已过期")?;
    let mut bytes = vec![];
    let mut reader = r.into_reader().take(size as u64 + 1);
    let mut chunk = [0u8; 64 * 1024];
    loop {
        if background && media_blocked() {
            return Err("通话或投屏期间暂缓媒体下载".into());
        }
        let n = reader.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..n]);
    }
    if bytes.len() != size as usize || hash(&bytes) != string(meta, "sha256")? {
        return Err("视频下载校验失败".into());
    }
    Ok(bytes)
}
fn sync_media(token: &str) -> Result<()> {
    let s = Store::open()?;
    let owner = s.owner(token)?;
    let mut attempted = HashSet::new();
    let mut media_error = None;
    loop {
        if media_blocked() {
            break;
        }
        let rows=s.rows("SELECT m.row FROM messages m LEFT JOIN settings r ON r.owner=m.owner AND r.key='mediaTry:'||m.id WHERE m.owner=? AND kind IN ('image','video') AND COALESCE(CAST(r.data AS INTEGER),0)<? AND NOT EXISTS(SELECT 1 FROM media b WHERE b.owner=m.owner AND b.id=m.id) ORDER BY COALESCE(CAST(r.data AS INTEGER),0),seq LIMIT 20",vec![owner.clone().into(),((now() as i64)-60000).into()])?;
        let rows = rows
            .into_iter()
            .filter(|r| !attempted.contains(r["id"].as_str().unwrap_or("")))
            .collect::<Vec<_>>();
        if rows.is_empty() {
            break;
        }
        for row in rows {
            if media_blocked() || super::api::load_creds().account_token.as_deref() != Some(token) {
                return Ok(());
            }
            let id = string(&row, "id")?;
            attempted.insert(id.to_owned());
            s.set(&owner, &format!("mediaTry:{id}"), &now().to_string())?;
            let peer = s.0.query_row(
                "SELECT peer FROM messages WHERE owner=? AND id=?",
                params![owner, id],
                |r| r.get::<_, String>(0),
            )?;
            let download = (|| -> Result<()> {
                if row["kind"] == "image" {
                    let result =
                        super::api::social_remote("local-image", token, json!({"messageId":id}))?;
                    let data = STANDARD.decode(
                        string(&result, "image")?
                            .split(',')
                            .last()
                            .ok_or("图片格式不正确")?,
                    )?;
                    s.transaction(|| {
                        s.save_bytes(
                            &owner,
                            id,
                            &data,
                            "image/jpeg",
                            row["image"]["sha256"].as_str(),
                        )
                    })?;
                } else {
                    let bytes = download_video_policy(token, &peer, id, &row, true)?;
                    s.transaction(|| {
                        s.save_bytes(
                            &owner,
                            id,
                            &bytes,
                            "video/mp4",
                            row["video"]["sha256"].as_str(),
                        )
                    })?;
                }
                Ok(())
            })();
            if let Err(e) = download {
                media_error = Some(e.to_string());
            }
        }
    }
    s.set(&owner, "sync_error", media_error.as_deref().unwrap_or(""))?;
    acknowledge(&s, &owner, token)
}
fn schedule(token: &str) {
    static RUNNING: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    let running = RUNNING.get_or_init(|| Mutex::new(HashSet::new()));
    if !running.lock().unwrap().insert(token.into()) {
        return;
    }
    let token = token.to_owned();
    std::thread::spawn(move || {
        let result = sync_feed(&token).and_then(|_| sync_media(&token));
        if let Err(e) = result {
            if let Ok(s) = Store::open() {
                if let Ok(id) = s.owner(&token) {
                    let _ = s.set(&id, "sync_error", &e.to_string());
                }
            }
        }
        running.lock().unwrap().remove(&token);
    });
}
pub fn display_error(e: &(dyn std::error::Error + 'static)) -> String {
    if e.downcast_ref::<rusqlite::Error>().is_some() {
        return "无法读取或保存本地聊天记录，请检查可用存储空间".into();
    }
    if e.downcast_ref::<std::io::Error>().is_some() {
        return "无法读取或保存聊天备份，请检查存储空间和文件权限".into();
    }
    if e.downcast_ref::<serde_json::Error>().is_some()
        || e.downcast_ref::<base64::DecodeError>().is_some()
        || e.downcast_ref::<std::string::FromUtf8Error>().is_some()
    {
        return "备份文件格式不正确或已损坏".into();
    }
    e.to_string()
}
pub fn social(op: &str, token: &str, body: Value) -> std::result::Result<Value, String> {
    social_inner(op, token, body).map_err(|e| display_error(e.as_ref()))
}
fn social_inner(op: &str, token: &str, body: Value) -> Result<Value> {
    if ![
        "state",
        "messages",
        "history",
        "message-context",
        "send",
        "send-image",
        "recall",
        "clear-history",
        "read",
        "message-image",
        "message-video",
    ]
    .contains(&op)
    {
        let value = super::api::social_remote(op, token, body)?;
        if op.starts_with("call-") {
            let mut calls = value["calls"].as_array().cloned().unwrap_or_default();
            if value["call"].is_object() {
                calls.push(value["call"].clone());
            }
            let busy = calls.iter().any(|c| {
                c["owned"] == true
                    && ["ringing", "active"].contains(&c["status"].as_str().unwrap_or(""))
            });
            if busy {
                MEDIA_BUSY.fetch_or(2, std::sync::atomic::Ordering::Relaxed);
            } else {
                MEDIA_BUSY.fetch_and(!2, std::sync::atomic::Ordering::Relaxed);
            }
        }
        return Ok(value);
    }
    let s = Store::open()?;
    let owner = s.owner(token)?;
    if ["messages", "history", "message-context"].contains(&op) {
        // Do not block the UI on media downloads; one quick delivery page is enough.
        let feed = super::api::social_remote(
            "local-feed",
            token,
            json!({"after":s.setting(&owner,"after")?.unwrap_or_else(||"0".into()),"edit":s.setting(&owner,"edit")?.unwrap_or_else(||"0".into())}),
        );
        let error = match feed {
            Ok(feed) => {
                s.apply(&owner, &feed)?;
                None
            }
            Err(e) => Some(e),
        };
        schedule(token);
        let mut result = s.query(&owner, op, &body)?;
        result["syncError"] = json!(error);
        return Ok(result);
    }
    if ["message-image", "message-video"].contains(&op) {
        let id = string(&body, "messageId")?;
        let row = s.message(&owner, id)?;
        if row.as_ref().is_some_and(|r| r["kind"] == "recalled") {
            return Err("媒体已撤回".into());
        }
        if let Some(bytes) = s.bytes(&owner, id)? {
            return Ok(if op == "message-image" {
                json!({"image":format!("data:image/jpeg;base64,{}",STANDARD.encode(bytes))})
            } else {
                json!({"message":row.ok_or("消息不存在")?})
            });
        }
    }
    let result = super::api::social_remote(op, token, body.clone());
    let value = match result {
        Ok(v) => v,
        Err(e) => {
            if op == "state" && e.contains("连不上服务器") {
                if let Some(state) = s.setting(&owner, "state")? {
                    let mut v: Value = serde_json::from_str(&state)?;
                    v["offline"] = json!(true);
                    return s.decorate(&owner, v);
                }
            }
            return Err(e.into());
        }
    };
    if op == "state" {
        s.set(&owner, "state", &value.to_string())?;
        schedule(token);
    }
    if ["send", "send-image", "recall"].contains(&op) {
        s.transaction(|| s.merge(&owner, string(&body, "peerId")?, &value["message"]))?;
        schedule(token);
    }
    if op == "clear-history" {
        s.transaction(|| {
            s.clear(
                &owner,
                string(&body, "peerId")?,
                number(&value, "clearedThrough")?,
            )
        })?;
    }
    if op == "message-image" {
        let id = string(&body, "messageId")?;
        if let Some(row) = s.message(&owner, id)? {
            let bytes = STANDARD.decode(
                string(&value, "image")?
                    .split(',')
                    .last()
                    .ok_or("图片格式不正确")?,
            )?;
            s.transaction(|| {
                s.save_bytes(
                    &owner,
                    id,
                    &bytes,
                    "image/jpeg",
                    row["image"]["sha256"].as_str(),
                )
            })?;
        }
    }
    if op == "read" {
        s.set(
            &owner,
            &format!("read:{}", string(&body, "peerId")?),
            string(&body, "seq")?,
        )?;
    }
    if op == "state" {
        s.decorate(&owner, value)
    } else {
        Ok(value)
    }
}
pub fn record(token: &str, peer: &str, row: &Value) -> std::result::Result<(), String> {
    (|| -> Result<()> {
        let s = Store::open()?;
        let owner = s.owner(token)?;
        s.transaction(|| s.merge(&owner, peer, row))?;
        schedule(token);
        Ok(())
    })()
    .map_err(|e| display_error(e.as_ref()))
}

pub fn sync_now(token: &str) -> Result<()> {
    sync_feed(token)?;
    sync_media(token)
}
