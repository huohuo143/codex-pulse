const ENDPOINT = "https://api.github.com/repos/huohuo143/codex-pulse/releases";
function parse(v) {
  const m = String(v).match(
    /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/,
  );
  return m ? { parts: m.slice(1, 4).map(Number), pre: m[4] || null } : null;
}
function compare(a, b) {
  a = parse(a);
  b = parse(b);
  if (!a || !b) return null;
  for (let i = 0; i < 3; i++)
    if (a.parts[i] !== b.parts[i]) return Math.sign(a.parts[i] - b.parts[i]);
  if (a.pre === b.pre) return 0;
  if (!a.pre) return 1;
  if (!b.pre) return -1;
  const x = a.pre.split("."),
    y = b.pre.split(".");
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if (x[i] === undefined) return -1;
    if (y[i] === undefined) return 1;
    if (x[i] === y[i]) continue;
    const xn = /^\d+$/.test(x[i]),
      yn = /^\d+$/.test(y[i]);
    if (xn && yn) return Math.sign(Number(x[i]) - Number(y[i]));
    if (xn !== yn) return xn ? -1 : 1;
    return x[i] < y[i] ? -1 : 1;
  }
  return 0;
}
class UpdateService {
  constructor(
    store,
    { fetcher = global.fetch, version = require("../../package.json").version, now = () => Date.now() } = {},
  ) {
    this.store = store;
    this.fetcher = fetcher;
    this.version = version;
    this.now = now;
    this.state = store.read("updates-v1", {
      checkedAt: null,
      message: "尚未检查更新",
    });
    if (this.state.version && compare(this.state.version, this.version) <= 0)
      this.state = { ...this.state, available: false, url: null, message: "已是最新 Windows 功能基线" };
    this.pending = null;
  }
  async check(force = false) {
    if (this.pending) return this.pending;
    if (!force && this.now() - Date.parse(this.state.checkedAt) < 86400000)
      return this.state;
    this.pending = this.fetch().finally(() => (this.pending = null));
    return this.pending;
  }
  async fetch() {
    const checkedAt = new Date(this.now()).toISOString();
    try {
      const r = await this.fetcher(ENDPOINT, {
        headers: { Accept: "application/vnd.github+json" },
        signal: AbortSignal.timeout(12000),
      });
      if (!r.ok) throw new Error();
      const releases = await r.json();
      if (!Array.isArray(releases)) throw new Error();
      const release = releases
        .filter((r) => !r.draft && !r.prerelease && parse(r.tag_name))
        .sort((a, b) => compare(b.tag_name, a.tag_name))[0];
      if (!release) throw new Error();
      const newer = compare(release.tag_name, this.version) > 0;
      const asset =
        release.assets?.find(
          (a) =>
            /windows.*x64.*安装版\.exe$/i.test(a.name) &&
            !a.name.includes("免安装"),
        ) || release.assets?.find((a) => /windows.*x64.*\.exe$/i.test(a.name));
      const url = asset?.browser_download_url;
      const valid =
        url &&
        url.startsWith(
          "https://github.com/huohuo143/codex-pulse/releases/download/",
        );
      this.state = {
        checkedAt,
        version: release.tag_name,
        available: newer && !!valid,
        url: newer && valid ? url : null,
        page: "https://github.com/huohuo143/codex-pulse/releases",
        message: newer
          ? valid
            ? "发现 Windows 新版 " + release.tag_name
            : "发现新版 " + release.tag_name + "，暂无 Windows x64 安装包"
          : "已是最新 Windows 功能基线",
      };
    } catch {
      this.state = {
        ...this.state,
        checkedAt,
        error: "更新检查失败，请稍后重试",
        message: "更新检查失败，请稍后重试",
      };
    }
    this.store.write("updates-v1", this.state);
    return this.state;
  }
}
module.exports = { UpdateService, compare, parse };
