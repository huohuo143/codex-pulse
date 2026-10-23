(function(root) {
  function parse(value) {
    if (typeof value !== 'string' || !/^(?:\d+|[1-9]\d{0,2}(?:,\d{3})+)(?:\.\d+)?$/.test(value.trim())) throw new Error('数量须为正数，千位分组应写成 1,000；不能使用 1,5 或 2,00');
    const number = Number(value.trim().replace(/,/g, ''));
    if (!Number.isFinite(number) || number <= 0) throw new Error('数量须为有限正数');
    return number;
  }
  const api = { parse };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.CreditAmount = api;
})(globalThis);
