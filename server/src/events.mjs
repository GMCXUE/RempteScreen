// 轻量事件总线：给长轮询（long-polling）用。
//
// 为什么不用 WebSocket：服务端刻意保持**零第三方依赖**（见 README），
// 而我们的推送是单向的（服务端 → 客户端），长轮询就够用：
//   · 服务端把请求挂住不返回，一有变化立刻写回 → 延迟毫秒级
//   · 客户端不需要额外协议栈，HTTP 客户端原生支持
//   · 每个等待者只占一个空闲 HTTP 连接（本项目规模下完全够）
//
// key 是任意字符串：设备用 `device:<id>`，观看请求用 `request:<id>`。

const waiters = new Map(); // key -> Set<resolve>

/** 注册一个等待者，返回取消函数。 */
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
    // 客户端断开连接时（长轮询特有的情况）也要清掉等待者
    if (timer.unref) timer.unref();
  });
}

/** 唤醒某个 key 上的全部等待者。 */
export function notify(key) {
  const set = waiters.get(key);
  if (!set) return;
  // 复制一份再回调：回调里会把自己从集合中摘掉
  for (const resolve of [...set]) resolve();
}

/** 当前等待者数量（诊断用）。 */
export function waiterCount() {
  let total = 0;
  for (const set of waiters.values()) total += set.size;
  return total;
}
