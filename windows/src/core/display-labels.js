(function (root) {
  // Percent signs are valid in ordinary file names. Decode only labels that
  // came from a file URL, and never feed the display value back into identity.
  function fromFileURL(value, originalPath) {
    const text = String(value ?? "");
    if (!/^file:\/\//i.test(String(originalPath ?? ""))) return text;
    try {
      const url = new URL(originalPath);
      if (url.protocol !== "file:") return text;
      const decoded = decodeURIComponent(text);
      return /[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/.test(decoded)
        ? text
        : decoded;
    } catch {
      return text;
    }
  }
  const api = {
    projectName: (name, originalPath) => {
      const text = String(name ?? "");
      try {
        const component = new URL(originalPath).pathname.replace(/\/+$/, "").split("/").at(-1);
        return text === component ? fromFileURL(text, originalPath) : text;
      } catch { return text; }
    },
    projectPath: (originalPath) => fromFileURL(originalPath, originalPath),
  };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DisplayLabels = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
