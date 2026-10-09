// 一次性迁移：旧 SQLite（node:sqlite）→ PostgreSQL。
//
// 用法（在 device-service 新镜像的容器里执行，同时挂载旧数据卷并连着 PG）：
//   node scripts/migrate-sqlite-to-pg.mjs [--dry-run]
//
// 环境变量：
//   DATABASE_FILE  旧 SQLite 文件路径（默认 /data/remotescreen.db）
//   DATABASE_URL   PostgreSQL 连接串
//
// 迁移内容：users、sessions 全量；devices 按规则去重 ——
// 同一用户下「同名同平台」的多台设备是旧版客户端凭据不持久化堆出来的历史残留，
// 组内只保留最近活跃的一台，其余（比最新心跳早 1 小时以上）丢弃。

import { DatabaseSync } from 'node:sqlite';
import process from 'node:process';
import pg from 'pg';
import { openDatabase } from '../src/db.mjs';

const DRY_RUN = process.argv.includes('--dry-run');
const SQLITE_FILE = process.env.DATABASE_FILE ?? '/data/remotescreen.db';
const PG_URL = process.env.DATABASE_URL;

if (!PG_URL) {
  console.error('缺少 DATABASE_URL');
  process.exit(1);
}

const sqlite = new DatabaseSync(SQLITE_FILE, { readOnly: true });

// MARK: - 写入

const count = async (sql, params = []) => {
  const r = await pool.query(sql, params);
  return Number(r.rows[0]?.n ?? 0);
};

const insertUsers = async (rows) => {
  for (const r of rows) {
    await pool.query(
      `INSERT INTO users (id, email, name, password_salt, password_hash, created_at)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (id) DO NOTHING`,
      [r.id, r.email, r.name, r.password_salt, r.password_hash, r.created_at],
    );
  }
};

const insertSessions = async (rows) => {
  for (const r of rows) {
    await pool.query(
      `INSERT INTO sessions (token_hash, user_id, created_at, expires_at)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (token_hash) DO NOTHING`,
      [r.token_hash, r.user_id, r.created_at, r.expires_at],
    );
  }
};

const insertDevices = async (rows) => {
  for (const r of rows) {
    await pool.query(
      `INSERT INTO devices (
         device_id, user_id, name, platform,
         password_salt, password_hash, session_token_hash,
         registered_at, last_heartbeat_at
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       ON CONFLICT (device_id) DO UPDATE SET
         user_id = excluded.user_id, name = excluded.name, platform = excluded.platform,
         password_salt = excluded.password_salt, password_hash = excluded.password_hash,
         session_token_hash = excluded.session_token_hash,
         registered_at = excluded.registered_at, last_heartbeat_at = excluded.last_heartbeat_at`,
      [r.device_id, r.user_id, r.name, r.platform, r.password_salt, r.password_hash,
        r.session_token_hash, r.registered_at, r.last_heartbeat_at],
    );
  }
};

// MARK: - 去重

/** 同用户下同名同平台的分组去重，返回要保留的行。 */
const dedupeDevices = (rows) => {
  const groups = new Map();
  for (const r of rows) {
    const key = `${r.user_id}|${r.name}|${r.platform}`;
    const list = groups.get(key) ?? [];
    list.push(r);
    groups.set(key, list);
  }

  const kept = [];
  const dropped = [];
  for (const [key, list] of groups) {
    list.sort((a, b) => b.last_heartbeat_at - a.last_heartbeat_at);
    kept.push(list[0]);
    // 组内其余设备：比最新心跳早 1 小时以上的都是凭据不持久化时代的历史残留
    for (const stale of list.slice(1)) {
      if (list[0].last_heartbeat_at - stale.last_heartbeat_at > 3600 * 1000) {
        dropped.push(stale);
      } else {
        kept.push(stale); // 活跃度接近的可能真是两台设备，宁可多留
      }
    }
    if (list.length > 1) {
      console.log(`  分组 ${key}：${list.length} 台 → 保留 ${list[0].device_id}`);
    }
  }
  return { kept, dropped };
};

// MARK: - 主流程

let pool;

const main = async () => {
  // 复用服务的建表与就绪重试逻辑（PG 可能比迁移容器晚就绪）
  await openDatabase();
  pool = new pg.Pool({ connectionString: PG_URL });

  const users = sqlite.prepare('SELECT * FROM users').all();
  const sessions = sqlite.prepare('SELECT * FROM sessions').all();
  const devices = sqlite.prepare('SELECT * FROM devices').all();
  console.log(`SQLite 中：${users.length} 个账号 / ${sessions.length} 个会话 / ${devices.length} 台设备`);

  const { kept, dropped } = dedupeDevices(devices);
  console.log(`设备去重：保留 ${kept.length} 台，丢弃 ${dropped.length} 台历史重复`);
  for (const d of dropped) {
    console.log(`  丢弃 ${d.device_id}  ${d.platform}  ${d.name}  （最后心跳 ${new Date(d.last_heartbeat_at).toISOString().slice(0, 16)}）`);
  }

  if (DRY_RUN) {
    console.log('dry-run，不写库');
    return;
  }

  await insertUsers(users);
  await insertSessions(sessions);
  await insertDevices(kept);

  console.log('写入完成。校验：');
  console.log(`  users=${await count('SELECT COUNT(*) AS n FROM users')}` +
    ` sessions=${await count('SELECT COUNT(*) AS n FROM sessions')}` +
    ` devices=${await count('SELECT COUNT(*) AS n FROM devices')}`);
};

main()
  .then(() => Promise.all([sqlite.close(), pool ? pool.end() : Promise.resolve()]))
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('迁移失败：', error);
    process.exit(1);
  });
