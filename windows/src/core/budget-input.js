(function (root) {
  function parse(text) {
    const trimmed = String(text ?? "").trim();
    if (!trimmed) throw new Error("请输入每月 Token 上限");
    if (!/^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)$/.test(trimmed))
      throw new Error("请输入正整数，或使用英文逗号分隔千位，例如 2,000,000");
    const value = Number(trimmed.replace(/,/g, ""));
    if (!Number.isSafeInteger(value))
      throw new Error("输入的 Token 上限过大，请减小数值");
    if (value <= 0) throw new Error("预算必须大于 0 Token");
    return value;
  }
  const api = { parse };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.ProjectBudgetInput = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
