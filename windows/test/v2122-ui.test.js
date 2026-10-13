const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const budgetInput = require("../src/core/budget-input");
const labels = require("../src/core/display-labels");
const { mount } = require("../src/renderer/budget-editor");
const errorMessages = require("../src/renderer/error-message");

test("Electron IPC errors show the real reason while unfamiliar error text remains intact", () => {
  assert.equal(errorMessages.readable(new Error("Error invoking remote method 'refresh': Error: 官方数据刷新失败")), "官方数据刷新失败");
  assert.equal(errorMessages.readable("Error invoking remote method 'set-budget': Error: 磁盘写入失败"), "磁盘写入失败");
  assert.equal(errorMessages.readable("Unexpected disk status E42"), "Unexpected disk status E42");
  assert.equal(errorMessages.readable(new TypeError("Unexpected value")), "Unexpected value");
});

test("budget input accepts positive whole Tokens and validated thousands separators", () => {
  for (const [text, value] of [["1", 1], [" 2,000,000 ", 2000000], ["00012", 12], ["9,007,199,254,740,991", Number.MAX_SAFE_INTEGER]])
    assert.equal(budgetInput.parse(text), value);
});
test("budget input never turns empty, decimal, exponent or malformed separators into a budget", () => {
  for (const text of ["", " \n ", "0", "0,000", "-1", "+2", "2.5", "2e6", "1_000", "2,00", "2,000,", ",123", "1234,567", "１２３", "2 000", "2，000", "9007199254740992", "1/2"])
    assert.throws(() => budgetInput.parse(text), Error, text);
});
test("project display decodes file URL labels once without changing ordinary paths or source identity", () => {
  const name = "%E7%AE%97%E5%8A%9B%20%2520";
  const projectPath = "file:///C:/research/" + name;
  const project = Object.freeze({ id: projectPath, projectName: name, projectPath });
  assert.equal(labels.projectName(project.projectName, project.projectPath), "算力 %20");
  assert.equal(labels.projectPath(project.projectPath), "file:///C:/research/算力 %20");
  assert.equal(project.id, projectPath);
  assert.equal(project.projectName, name);
  assert.equal(labels.projectName("literal%20name", "C:\\literal%20name"), "literal%20name");
  assert.equal(labels.projectPath("/tmp/literal%20name"), "/tmp/literal%20name");
  assert.equal(labels.projectName("100%", "file:///C:/100%"), "100%");
  assert.equal(labels.projectName("a%0Ab", "file:///C:/a%0Ab"), "a%0Ab");
  assert.equal(labels.projectName("Trial%20Control", "file:///work/project"), "Trial%20Control");
  assert.equal(labels.projectName("项目", "file:///work/%E9%A1%B9%E7%9B%AE"), "项目");
  assert.equal(labels.projectName("%E9%A1%B9%E7%9B%AE", "file:///work/%E9%A1%B9%E7%9B%AE/"), "项目");
});

class Element {
  constructor(tag = "div") {
    this.tag = tag; this.value = ""; this.textContent = ""; this.disabled = false;
    this.dataset = {}; this.attributes = {}; this.children = []; this.listeners = {};
    const names = new Set();
    this.classList = { add: (...values) => values.forEach((v) => names.add(v)),
      remove: (...values) => values.forEach((v) => names.delete(v)), contains: (value) => names.has(value) };
  }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  fire(name, event = {}) { return this.listeners[name]?.(event); }
  focus() { this.focused = true; }
  replaceChildren(...children) {
    this.children = children;
    if (this.tag === "select") this.value = children[0]?.value || "";
  }
}
function documentFixture() {
  const nodes = new Map();
  return { body: new Element(), nodes,
    querySelector(selector) {
      if (!nodes.has(selector)) nodes.set(selector, new Element(selector === "#budgetProject" ? "select" : "div"));
      return nodes.get(selector);
    },
    querySelectorAll() { return []; }, createElement(tag) { return new Element(tag); } };
}
const firstProject = { id: "raw-a", projectName: "%E9%A1%B9%E7%9B%AE", projectPath: "file:///C:/%E9%A1%B9%E7%9B%AE" };
const secondProject = { id: "raw-b", projectName: "Second", projectPath: "C:\\Second" };
function editorFixture(api = { setBudget: async () => [] }) {
  const document = documentFixture(), notices = [];
  const controller = mount({ document, api, notify: (...args) => notices.push(args) });
  const state = { tokenStats: { monthTopProjects: [firstProject, secondProject] }, budgets: [{ ...firstProject, monthlyTokenLimit: 1000 }] };
  controller.sync(state);
  const get = (id) => document.querySelector("#" + id);
  const edit = (value) => { get("budgetLimit").value = value; get("budgetLimit").fire("input"); };
  return { controller, state, notices, get, edit };
}
test("budget editor keeps selected identity, loads existing amount and never submits empty or zero input", async () => {
  const calls = [];
  const f = editorFixture({ setBudget: async (value) => { calls.push(value); return []; } });
  assert.equal(f.get("budgetProject").value, "raw-a");
  assert.equal(f.get("budgetProject").children[0].textContent, "项目");
  assert.equal(f.get("budgetLimit").value, "1,000");
  for (const value of ["", "0", "3,00"]) {
    f.edit(value);
    assert.equal(f.get("saveBudget").disabled, true);
    await f.get("saveBudget").fire("click");
    assert.equal(f.get("budgetLimit").value, value);
    assert.equal(f.get("budgetFeedback").dataset.kind, "error");
  }
  assert.equal(calls.length, 0);
});
test("budget save failures preserve draft across background updates and project switching", async () => {
  const f = editorFixture({ setBudget: async () => { throw new Error("Error invoking remote method 'set-budget': Error: 磁盘写入失败"); } });
  f.edit("2,000,000"); await f.get("saveBudget").fire("click");
  f.controller.sync(f.state);
  assert.equal(f.get("budgetLimit").value, "2,000,000");
  assert.equal(f.get("budgetFeedback").textContent, "磁盘写入失败");
  assert.equal(f.get("saveBudget").disabled, false);
  assert.deepEqual(f.notices, [["磁盘写入失败", "error"]]);
  f.get("budgetProject").value = "raw-b"; f.get("budgetProject").fire("change");
  f.edit("25"); f.get("budgetProject").value = "raw-a"; f.get("budgetProject").fire("change");
  assert.equal(f.get("budgetLimit").value, "2,000,000");
});
test("budget save coalesces repeated actions and preserves raw identity during submission", async () => {
  let resolve;
  const calls = [];
  const f = editorFixture({ setBudget: (value) => { calls.push(value); return new Promise((done) => { resolve = done; }); } });
  f.edit("3,000"); const first = f.get("saveBudget").fire("click");
  await f.get("saveBudget").fire("click");
  await f.get("removeBudget").fire("click");
  f.controller.sync(f.state);
  assert.equal(f.get("saveBudget").disabled, true);
  assert.equal(f.get("budgetProject").disabled, true);
  assert.equal(f.get("budgetLimit").value, "3,000");
  assert.deepEqual(calls, [{ id: "raw-a", limit: 3000 }]);
  resolve([{ ...firstProject, monthlyTokenLimit: 3000 }]); await first;
  assert.equal(f.get("saveBudget").disabled, false);
  assert.deepEqual(f.notices, [["预算已保存", "success"]]);
});
test("budget removal is explicit and only clears input after durable success", async () => {
  const calls = [];
  const f = editorFixture({ setBudget: async (value) => { calls.push(value); return []; } });
  await f.get("removeBudget").fire("click");
  assert.deepEqual(calls, [{ id: "raw-a", remove: true }]);
  assert.equal(f.get("budgetLimit").value, "");
  assert.equal(f.get("removeBudget").disabled, true);
  assert.deepEqual(f.notices, [["预算已删除", "success"]]);
});
test("budget controls explain an empty project list", () => {
  const f = editorFixture(); f.controller.sync({ tokenStats: {}, budgets: [] });
  assert.equal(f.get("saveBudget").disabled, true);
  assert.equal(f.get("budgetLimit").disabled, true);
  assert.match(f.get("budgetFeedback").textContent, /暂无已识别项目/);
});

function appFixture(refresh) {
  const document = documentFixture();
  const context = vm.createContext({ document, window: { suanli: { refresh } },
    DisplayLabels: labels, ErrorMessages: errorMessages, setTimeout: () => 1, clearTimeout: () => {} });
  const source = fs.readFileSync(path.join(__dirname, "../src/renderer/app.js"), "utf8");
  vm.runInContext(source.slice(0, source.indexOf("\nstart().catch(")), context);
  for (const name of ["renderCredits", "renderHourly", "renderDaily", "renderModels", "renderDevices", "renderInsights", "renderProjects", "renderRecent"])
    context[name] = () => {};
  const cost = { isUnavailable: true };
  const state = { main: {}, scannedFiles: 0, generatedAt: "2026-10-13T00:00:00Z", tokenStats: {
    sampleCount: 0, cost24Hours: cost, cost7Days: cost, costMonth: cost,
  } };
  vm.runInContext('appSubtitle = "v2.12.2 · 顺滑浮窗与本地工作分析";', context);
  return { context, document, state, get: (id) => document.querySelector("#" + id) };
}
test("refresh remains pending through intermediate status updates and ignores repeated clicks", async () => {
  let resolve, calls = 0;
  const f = appFixture(() => { calls++; return new Promise((done) => { resolve = done; }); });
  const request = f.context.requestRefresh();
  assert.equal(f.context.requestRefresh(), request);
  await Promise.resolve();
  f.context.renderStatus(f.state);
  assert.match(f.get("refreshState").textContent, /正在刷新/);
  assert.equal(f.get("refreshButton").disabled, true);
  assert.equal(f.document.body.classList.contains("loading"), true);
  resolve(); await request;
  assert.equal(calls, 1);
  assert.match(f.get("refreshState").textContent, /完整统计更新于/);
  assert.equal(f.get("refreshButton").disabled, false);
  assert.equal(f.document.body.classList.contains("loading"), false);
});
test("failed refresh releases controls, labels the error and recovers after the next valid status", async () => {
  let failing = true;
  const f = appFixture(async () => { if (failing) throw new Error("Error invoking remote method 'refresh': Error: 官方数据刷新失败"); });
  await f.context.requestRefresh();
  assert.equal(f.get("refreshButton").disabled, false);
  assert.equal(f.document.body.classList.contains("loading"), false);
  assert.equal(f.get("toast").dataset.kind, "error");
  assert.equal(f.get("toast").attributes.role, "alert");
  assert.match(f.get("subtitle").textContent, /读取失败/);
  assert.match(f.get("refreshState").textContent, /刷新失败/);
  assert.equal(f.get("toast").textContent, "官方数据刷新失败");
  f.context.renderStatus(f.state);
  assert.match(f.get("subtitle").textContent, /^v2\.12\.2/);
  assert.match(f.get("refreshState").textContent, /完整统计更新于/);
  failing = false;
  await f.context.requestRefresh();
  assert.equal(f.get("toast").classList.contains("show"), false);
  assert.equal(f.get("toast").textContent, "");
  failing = true; await f.context.requestRefresh();
  // A later, unrelated action must survive even if its text happens to match.
  f.context.showToast("官方数据刷新失败", "error");
  failing = false; await f.context.requestRefresh();
  assert.equal(f.get("toast").classList.contains("show"), true);
  assert.equal(f.get("toast").textContent, "官方数据刷新失败");
});
test("action notifications keep refresh progress intact and use distinct success semantics", () => {
  const f = appFixture(async () => {});
  f.get("refreshState").textContent = "正在刷新额度、用量与重置雷达…";
  f.context.showToast("预算已保存", "success");
  assert.equal(f.get("toast").attributes.role, "status");
  assert.equal(f.get("toast").dataset.kind, "success");
  assert.match(f.get("refreshState").textContent, /正在刷新/);
});
