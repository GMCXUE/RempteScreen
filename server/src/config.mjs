// 服务配置。所有项都可通过环境变量覆盖，便于同一份代码跑在开发机与线上。

const num = (value, fallback) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

export const config = {
  port: num(process.env.PORT, 8787),
  host: process.env.HOST ?? '127.0.0.1',

  livekit: {
    // 客户端拿到的连接地址。生产环境必须是 wss 公网地址。
    url: process.env.LIVEKIT_URL ?? 'ws://127.0.0.1:7880',
    apiKey: process.env.LIVEKIT_API_KEY ?? 'devkey',
    apiSecret: process.env.LIVEKIT_API_SECRET ?? 'devsecret_devsecret_devsecret_32',
    // 签发的令牌有效期。投送会话通常不会太长，2 小时足够。
    tokenTtlSec: num(process.env.LIVEKIT_TOKEN_TTL_SEC, 7200),
  },

  heartbeat: {
    // 采集端按此间隔上报心跳
    intervalSec: num(process.env.HEARTBEAT_INTERVAL_SEC, 15),
    // 超过该时长未收到心跳即判定离线，需大于 intervalSec 的 2 倍以容忍抖动
    timeoutSec: num(process.env.HEARTBEAT_TIMEOUT_SEC, 45),
    // 离线判定的扫描间隔
    sweepIntervalSec: num(process.env.HEARTBEAT_SWEEP_SEC, 10),
  },

  device: {
    idLength: 9,
  },

  database: {
    // PostgreSQL 连接串。由 docker-compose 注入（生产）或本地 docker 传入（开发）。
    url: process.env.DATABASE_URL ?? 'postgres://remotescreen:remotescreen@127.0.0.1:5432/remotescreen',
  },

  auth: {
    // 用户会话有效期，默认 30 天
    sessionTtlSec: num(process.env.SESSION_TTL_SEC, 30 * 24 * 3600),
    nameMaxLength: 32,
    // 登录失败限流：窗口期内错误超过阈值即冷却
    loginWindowSec: num(process.env.LOGIN_WINDOW_SEC, 300),
    loginMaxFailures: num(process.env.LOGIN_MAX_FAILURES, 10),
    loginCooldownSec: num(process.env.LOGIN_COOLDOWN_SEC, 300),
  },

  password: {
    length: num(process.env.PASSWORD_LENGTH, 6),
    // 刻意剔除易混淆字符：0 O o、1 l I、i、u/v 中的视觉歧义项
    alphabet: '23456789abcdefghjkmnpqrstuvwxyz',
  },

  rateLimit: {
    // 同一设备在窗口期内允许的密码错误次数
    windowSec: num(process.env.RATE_LIMIT_WINDOW_SEC, 60),
    maxFailures: num(process.env.RATE_LIMIT_MAX_FAILURES, 5),
    // 触发后冷却多久才能再试
    cooldownSec: num(process.env.RATE_LIMIT_COOLDOWN_SEC, 60),
  },

  body: {
    // 请求体大小上限，防止超大请求打满内存
    maxBytes: num(process.env.BODY_MAX_BYTES, 16 * 1024),
  },
};
