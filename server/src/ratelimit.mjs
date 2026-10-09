// 通用滑动窗口限流。
//
// 刻意只用内存：限流状态属于「丢掉也无所谓」的数据，
// 服务重启后重新计数是可接受的代价，换来的是不必为它引入持久化。
// 代价是重启会清空计数器 —— 对暴力破解来说只是要求攻击者放慢一点，
// 真正的防线是 scrypt 的耗时与设备密码的短有效期。

export function createRateLimiter({ windowSec, maxFailures, cooldownSec }) {
  /** @type {Map<string, {failures: number[], cooldownUntil: number}>} */
  const buckets = new Map();

  const prune = (bucket, now) => {
    const windowMs = windowSec * 1000;
    bucket.failures = bucket.failures.filter((timestamp) => now - timestamp <= windowMs);
    return bucket.failures;
  };

  const bucketFor = (key) => {
    let bucket = buckets.get(key);
    if (!bucket) {
      bucket = { failures: [], cooldownUntil: 0 };
      buckets.set(key, bucket);
    }
    return bucket;
  };

  return {
    /** 是否处于冷却期。应在做任何昂贵计算之前调用。 */
    check(key) {
      const now = Date.now();
      const bucket = bucketFor(key);

      if (bucket.cooldownUntil > now) {
        return { blocked: true, retryAfterSec: Math.ceil((bucket.cooldownUntil - now) / 1000) };
      }

      const failures = prune(bucket, now).length;
      return { blocked: false, remainingAttempts: Math.max(0, maxFailures - failures) };
    },

    recordFailure(key) {
      const now = Date.now();
      const bucket = bucketFor(key);
      const failures = prune(bucket, now);
      failures.push(now);

      if (failures.length >= maxFailures) {
        bucket.cooldownUntil = now + cooldownSec * 1000;
        bucket.failures = [];
        return { cooldown: true, retryAfterSec: cooldownSec };
      }
      return { cooldown: false, remainingAttempts: maxFailures - failures.length };
    },

    recordSuccess(key) {
      buckets.delete(key);
    },

    resetAll() {
      buckets.clear();
    },
  };
}
