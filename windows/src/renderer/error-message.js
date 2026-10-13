(function (root) {
  function readable(error, fallback = "操作失败，请重试") {
    const message = String(error?.message ?? error ?? fallback).trim() || fallback;
    // Electron wraps IPC rejections with transport details. Remove only that
    // known prefix; an unfamiliar error and the actual reason remain intact.
    const cleaned = message.replace(
      /^(?:Error:\s*)?Error invoking remote method (?:'[^'\r\n]*'|"[^"\r\n]*"):\s*(?:Error:\s*)?/,
      "",
    );
    return cleaned || message;
  }
  const api = { readable };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.ErrorMessages = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
