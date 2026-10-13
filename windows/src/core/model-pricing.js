const builtin = require("./resources/model-prices-v1.json");
const { createHash } = require("node:crypto");
let active = builtin;
function validate(table, base = builtin) {
  if (
    table?.schemaVersion !== 1 ||
    !Number.isFinite(Date.parse(table.verifiedAt)) ||
    !Array.isArray(table.models) ||
    !table.models.length
  )
    throw new Error("价格表格式无效");
  const seen = new Set();
  for (const row of table.models) {
    if (
      typeof row.model !== "string" ||
      !/^[a-z0-9][a-z0-9._-]*$/.test(row.model) ||
      !Array.isArray(row.aliases)
    )
      throw new Error("模型名称或别名无效");
    for (const name of [row.model, ...row.aliases]) {
      if (
        typeof name !== "string" ||
        !/^[a-z0-9][a-z0-9._-]*$/.test(name) ||
        seen.has(name)
      )
        throw new Error("模型或别名冲突");
      seen.add(name);
    }
    for (const key of ["input", "cachedInput", "output"]) {
      if (key === "cachedInput" && row[key] === null) continue;
      if (
        typeof row[key] !== "number" ||
        !Number.isFinite(row[key]) ||
        row[key] < 0
      )
        throw new Error("价格必须是有限非负数");
    }
    for (const key of [
      "longContextInputMultiplier",
      "longContextOutputMultiplier",
      "longContextThresholdInputTokens",
    ])
      if (
        row[key] != null &&
        (typeof row[key] !== "number" ||
          !Number.isFinite(row[key]) ||
          row[key] <= 0)
      )
        throw new Error("长上下文规则无效");
    try {
      if (new URL(row.sourceURL).protocol !== "https:") throw 0;
    } catch {
      throw new Error("价格来源必须是 HTTPS 地址");
    }
  }
  const merged = {
    ...table,
    models: [
      ...base.models.filter(
        (r) => !table.models.some((n) => n.model === r.model),
      ),
      ...table.models,
    ],
  };
  const names = merged.models.flatMap((r) => [r.model, ...r.aliases]);
  if (new Set(names).size !== names.length)
    throw new Error("别名与已有模型冲突");
  return merged;
}
function version(table = active) {
  return createHash("sha256")
    .update(JSON.stringify(table))
    .digest("hex")
    .slice(0, 16);
}
function setPriceTable(table) {
  active = table ? validate(table) : builtin;
  return active;
}
function getPriceTable() {
  return active;
}
function preview(table) {
  const merged = validate(table);
  return {
    table: merged,
    version: version(merged),
    changes: table.models.map((row) => ({
      model: row.model,
      before: active.models.find((r) => r.model === row.model) || null,
      after: row,
    })),
  };
}
function estimateCost(events, table = active) {
  const catalog = new Map(
    table.models.flatMap((r) => [r.model, ...r.aliases].map((n) => [n, r])),
  );
  let usd = 0,
    unpricedTokens = 0,
    pricedTokens = 0;
  const missing = new Set();
  for (const event of events) {
    const input = Math.max(0, Number(event.inputTokens) || 0),
      cached = Math.min(
        input,
        Math.max(0, Number(event.cachedInputTokens) || 0),
      ),
      output = Math.max(0, Number(event.outputTokens) || 0);
    const total = Math.max(input + output, Number(event.totalTokens) || 0),
      row = catalog.get(String(event.model || "unknown").toLowerCase());
    if (!row) {
      unpricedTokens += total;
      missing.add(event.model || "unknown");
      continue;
    }
    const long =
      row.longContextThresholdInputTokens != null &&
      input > row.longContextThresholdInputTokens;
    const im = long ? row.longContextInputMultiplier || 1 : 1,
      om = long ? row.longContextOutputMultiplier || 1 : 1;
    usd += ((input - cached) * row.input * im + output * row.output * om) / 1e6;
    pricedTokens += input - cached + output;
    if (row.cachedInput == null && cached > 0) {
      unpricedTokens += cached;
      missing.add(event.model);
    } else {
      usd += (cached * (row.cachedInput || 0) * im) / 1e6;
      pricedTokens += cached;
    }
  }
  const total = pricedTokens + unpricedTokens;
  return {
    usd,
    unpricedTokens,
    pricedTokens,
    coverage: total ? pricedTokens / total : 1,
    unpricedModels: [...missing].sort(),
    isPartial: unpricedTokens > 0,
    isUnavailable: unpricedTokens > 0 && pricedTokens === 0,
    priceVersion: version(table),
    verifiedAt: table.verifiedAt,
  };
}
module.exports = {
  builtin,
  validate,
  preview,
  version,
  setPriceTable,
  getPriceTable,
  estimateCost,
};
