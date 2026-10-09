// 预加载脚本：向渲染进程暴露一组最小化的、受控的接口。
//
// 渲染进程拿不到 Node、拿不到文件系统，也拿不到任何长期凭据的读写能力。

const { contextBridge, ipcRenderer } = require('electron');

const subscribe = (channel, listener) => {
  const wrapped = (_event, payload) => listener(payload);
  ipcRenderer.on(channel, wrapped);
  return () => ipcRenderer.removeListener(channel, wrapped);
};

contextBridge.exposeInMainWorld('remoteScreen', {
  // 环境信息
  getPlatformInfo: () => ipcRenderer.invoke('platform:info'),

  // 采集源
  listSources: () => ipcRenderer.invoke('sources:list'),
  prepareCapture: (options) => ipcRenderer.invoke('capture:prepare', options),

  // 设备会话
  registerSession: (payload) => ipcRenderer.invoke('session:register', payload),
  getCredentials: () => ipcRenderer.invoke('session:credentials'),
  refreshPassword: () => ipcRenderer.invoke('session:refreshPassword'),
  unregisterSession: () => ipcRenderer.invoke('session:unregister'),

  // 事件
  onHeartbeat: (listener) => subscribe('session:heartbeat', listener),
  onSessionError: (listener) => subscribe('session:error', listener),

  // 自检
  reportSelfTest: (report) => ipcRenderer.invoke('selftest:report', report),
});
