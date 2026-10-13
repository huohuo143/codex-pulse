const fsp = require("node:fs/promises");

const ENDPOINT = "https://api.frankfurter.dev/v2/rate/USD/CNY";

class ExchangeRateService {
  constructor({
    cachePath,
    fetcher = global.fetch,
    now = () => new Date(),
  } = {}) {
    this.cachePath = cachePath;
    this.fetcher = fetcher;
    this.now = now;
  }

  async cached() {
    try {
      const value = JSON.parse(await fsp.readFile(this.cachePath, "utf8"));
      return Number(value.rate) > 0 ? value : null;
    } catch {
      return null;
    }
  }

  async current({ force = false } = {}) {
    const cached = await this.cached();
    const today = this.now().toISOString().slice(0, 10);
    if (!force && cached?.fetchedOn === today) return cached;
    try {
      const response = await this.fetcher(ENDPOINT, {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(10_000),
      });
      if (!response.ok) throw new Error(`http_${response.status}`);
      const root = await response.json();
      const rate = Number(root.rate || root.rates?.CNY);
      if (!(rate > 0)) throw new Error("invalid_rate");
      const value = {
        rate,
        rateDate: root.date || today,
        fetchedOn: today,
        source: "Frankfurter",
      };
      await fsp.mkdir(require("node:path").dirname(this.cachePath), {
        recursive: true,
      });
      await fsp.writeFile(this.cachePath, JSON.stringify(value, null, 2));
      return value;
    } catch {
      return cached;
    }
  }
}

module.exports = { ExchangeRateService, ENDPOINT };
