// 持久化层 —— PostgreSQL。
//
// 之前用 node:sqlite（单文件、零依赖），迁移到 PG 容器的原因：
// 数据与服务器解耦、运维工具链成熟、以后多实例水平扩展不用动代码。
// 连接串从 DATABASE_URL 读取，由 docker-compose 注入。
//
// schema 与原 SQLite 完全一致，时间戳仍是毫秒整数（BIGINT），
// 旧数据用 scripts/migrate-sqlite-to-pg.mjs 一次性搬过来。

import pg from 'pg';
import { config } from './config.mjs';

let pool = null;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id            TEXT PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  name          TEXT NOT NULL,
  password_salt TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at    BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS devices (
  device_id          TEXT PRIMARY KEY,
  user_id            TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name               TEXT NOT NULL,
  platform           TEXT NOT NULL,
  password_salt      TEXT NOT NULL,
  password_hash      TEXT NOT NULL,
  session_token_hash TEXT NOT NULL,
  registered_at      BIGINT NOT NULL,
  last_heartbeat_at  BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id);
`;

/**
 * 增量迁移（幂等）。
 *
 * password_plain：连接密码是「设备屏幕上展示给对方的分享码」（ToDesk 同理），
 * 不是用户口令。为了让它在重启后保持不变、并且设备随时能把它显示出来，
 * 这里做可逆保存；校验仍走 password_hash，不依赖明文比较。
 */
const MIGRATIONS = `
ALTER TABLE devices ADD COLUMN IF NOT EXISTS password_plain TEXT NOT NULL DEFAULT '';
`;

/** 建立连接池并完成建表。重复调用返回同一个池。 */
export async function openDatabase() {
  if (pool) return pool;

  pool = new pg.Pool({
    connectionString: config.database.url,
    max: 10,
    idleTimeoutMillis: 30_000,
  });

  // 容器编排里 PG 可能比本服务晚就绪，重试几次再放弃
  for (let attempt = 1; ; attempt += 1) {
    try {
      await pool.query('SELECT 1');
      break;
    } catch (error) {
      if (attempt >= 10) throw error;
      const waitMs = attempt * 1000;
      console.warn(`数据库尚未就绪（第 ${attempt} 次），${waitMs}ms 后重试：${error.code ?? error.message}`);
      await new Promise((resolve) => setTimeout(resolve, waitMs));
    }
  }

  await pool.query(SCHEMA);
  await pool.query(MIGRATIONS);
  return pool;
}

export function getPool() {
  if (!pool) throw new Error('数据库尚未初始化，请先调用 openDatabase()');
  return pool;
}

/** 执行一条查询，返回 rows 数组。 */
export async function query(sql, params = []) {
  const result = await getPool().query(sql, params);
  return result.rows;
}

export async function closeDatabase() {
  if (pool) {
    await pool.end();
    pool = null;
  }
}

/** 清理已过期的会话。启动时与定时任务里调用。 */
export async function purgeExpiredSessions() {
  const result = await getPool().query('DELETE FROM sessions WHERE expires_at <= $1', [Date.now()]);
  return result.rowCount ?? 0;
}
