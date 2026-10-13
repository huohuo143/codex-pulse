const { contextBridge, ipcRenderer } = require("electron");
const api = {};
for (const [name, channel] of Object.entries({
  bootstrap: "get-bootstrap",
  refresh: "refresh",
  refreshRadar: "refresh-radar",
  setCompact: "set-compact",
  setSettings: "set-settings",
  setCard: "set-card",
  copySummary: "copy-summary",
  exportCSV: "export-csv",
  exportQuotaHistory: "export-quota-history",
  setExpiryBatch: "set-expiry-batch",
  networkOnline: "network-online",
  windowAction: "window-action",
  openPath: "open-path",
  openExternal: "open-external",
  showSection: "show-section",
  setBudget: "set-budget",
  setExpiry: "set-expiry",
  markRadar: "mark-radar",
  checkUpdates: "check-updates",
  previewPrices: "preview-prices",
  applyPrices: "apply-prices",
  exportDiagnostics: "export-diagnostics",
  recover: "recover",
  setDetail: "set-detail",
}))
  api[name] = (...args) => ipcRenderer.invoke(channel, ...args);
for (const [name, channel] of Object.entries({
  onStatus: "status",
  onStatusError: "status-error",
  onRadarStatus: "radar-status",
  onRadarLoading: "radar-loading",
  onSettings: "settings-changed",
  onCompact: "compact-changed",
  onToast: "toast",
}))
  api[name] = (callback) => {
    const listener = (_, value) => callback(value);
    ipcRenderer.on(channel, listener);
    return () => ipcRenderer.removeListener(channel, listener);
  };
contextBridge.exposeInMainWorld("suanli", api);
