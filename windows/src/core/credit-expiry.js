const { randomUUID } = require("node:crypto");
function validDate(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
    Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
}
function forAccount(rows, scope) {
  return scope && Array.isArray(rows) ? rows.filter(r => r && r.accountScope === scope && validDate(r.expiresOn) && Number.isFinite(r.credits)).sort((a, b) => a.expiresOn.localeCompare(b.expiresOn)) : [];
}
function save(rows, value, scope) {
  rows = Array.isArray(rows) ? rows.filter(r => r && typeof r.id === "string") : [];
  if (!scope) throw new Error("等待当前账户载入后再记录批次");
  if (value?.remove) {
    if (!rows.some(r => r.id === value.id && r.accountScope === scope)) throw new Error("批次不存在");
    return rows.filter(r => r.id !== value.id || r.accountScope !== scope);
  }
  if (!value || !Number.isFinite(value.credits) || value.credits <= 0 || !validDate(value.grantedOn) || !validDate(value.expiresOn) ||
      value.expiresOn < value.grantedOn || !["confirmed", "estimated"].includes(value.kind) ||
      typeof value.evidence !== "string" || value.evidence.trim().length < 5 || value.evidence.length > 1000)
    throw new Error("请填写批次数量、有效发放/到期日期和至少 5 字的来源依据");
  if (value.id && !rows.some(r => r.id === value.id && r.accountScope === scope) &&
      !(value.recreate === true && /^[a-f0-9-]{36}$/i.test(value.id) && !rows.some(r => r.id === value.id))) throw new Error("批次不存在");
  const row = { id: value.id || randomUUID(), accountScope: scope, credits: value.credits, grantedOn: value.grantedOn,
    expiresOn: value.expiresOn, kind: value.kind, evidence: value.evidence.trim() };
  return [...rows.filter(r => r.id !== row.id), row];
}
module.exports = { validDate, forAccount, save };
