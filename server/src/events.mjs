// 轻量事件总线：给推送通道用（SSE 长连接 + 长轮询兜底）。
//
// 为什么不用 WebSocket：服务端刻意保持**零第三方依赖**（见 README），
// 而通知是纯单向（服务端 → 客户端）——SSE 只是一个长挂的 HTTP 流，
// 不需要协议升级、不需要依赖，断线重连也只是客户端重新发起请求。
// key 是任意字符串：设备用 `device:<id>`，观看请求用 `request:<id>`。

const waiters = new Map(); // key -> Set<resolve>          （长轮询用）
const subscribers = new Map(); // key -> Set<callback>      （SSE 用）

/** 长轮询：注册一个一次性等待者，返回取消函数。 */
function addWaiter(key, resolve) {
  let set = waiters.get(key);
  if (!set) {
    set = new Set();
    waiters.set(key, set);
  }
  set.add(resolve);
  return () => {
    set.delete(resolve);
    if (set.size === 0) waiters.delete(key);
  };
}

/**
 * 等待某个 key 发生变化，最多等 timeoutMs 毫秒。
 * 返回 true 表示被唤醒，false 表示超时。
 */
export function waitFor(key, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (woken) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      removeWaiter();
      resolve(woken);
    };
    const removeWaiter = addWaiter(key, () => finish(true));
    const timer = setTimeout(() => finish(false), timeoutMs);
    if (timer.unref) timer.unref();
  });
}

/** SSE：持续订阅某个 key，返回退订函数。回调会收到通知时的负载（可能为空）。 */
export function subscribe(key, callback) {
  let set = subscribers.get(key);
  if (!set) {
    set = new Set();
    subscribers.set(key, set);
  }
  set.add(callback);
  return () => {
    set.delete(callback);
    if (set.size === 0) subscribers.delete(key);
  };
}

/** 唤醒某个 key：长轮询的等待者被释放，SSE 订阅者收到负载。 */
export function notify(key, payload = null) {
  const waitSet = waiters.get(key);
  if (waitSet) {
    for (const resolve of [...waitSet]) resolve();
  }
  const subSet = subscribers.get(key);
  if (subSet) {
    for (const callback of [...subSet]) {
      try {
        callback(payload);
      } catch (error) {
        // 单个订阅者出错不能影响别人
      }
    }
  }
}

/** 当前等待者与订阅者数量（诊断用）。 */
export function counts() {
  let waitersTotal = 0;
  for (const set of waiters.values()) waitersTotal += set.size;
  let subscribersTotal = 0;
  for (const set of subscribers.values()) subscribersTotal += set.size;
  return { waiters: waitersTotal, subscribers: subscribersTotal };
}
