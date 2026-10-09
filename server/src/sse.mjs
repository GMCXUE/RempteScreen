// SSE（Server-Sent Events）发送端。
//
// 通知是纯单向（服务端 → 客户端），SSE 只是一个长挂的 HTTP 流：
// 不需要协议升级（WebSocket 需要），也不需要第三方依赖。
// 客户端拿到流后逐行解析 `event:` / `data:`；断开就重连。

/** 把 HTTP 响应升级成 SSE 流，返回一个写入器。 */
export function openSSE(response) {
  response.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-store',
    Connection: 'keep-alive',
    'Access-Control-Allow-Origin': '*',
    'X-Accel-Buffering': 'no', // 若前面挂了 nginx，禁止它缓冲
  });
  if (typeof response.flushHeaders === 'function') response.flushHeaders();

  let closed = false;

  return {
    /** 推送一条事件。 */
    send(event, data) {
      if (closed || response.writableEnded) return;
      response.write('event: ' + event + '\ndata: ' + JSON.stringify(data) + '\n\n');
    },
    /** 注释行：不触发客户端事件，只用来保活/刷新中间设备。 */
    comment(text) {
      if (closed || response.writableEnded) return;
      response.write(': ' + text + '\n\n');
    },
    close() {
      if (!closed) {
        closed = true;
        response.end();
      }
    },
    onclose(callback) {
      response.on('close', () => {
        if (!closed) {
          closed = true;
          callback();
        }
      });
    },
  };
}
