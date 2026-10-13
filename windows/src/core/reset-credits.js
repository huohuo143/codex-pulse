const fsp = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const ENDPOINT =
  "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";

function decodeDate(value) {
  if (value == null) return null;
  if (typeof value === "number" || /^\d+(\.\d+)?$/.test(String(value))) {
    const raw = Number(value);
    const date = new Date(raw > 10_000_000_000 ? raw : raw * 1000);
    return Number.isFinite(date.getTime()) ? date.toISOString() : null;
  }
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

function decodeJWTAccountID(token) {
  try {
    const payload = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const root = JSON.parse(Buffer.from(payload, "base64").toString("utf8"));
    return root?.["https://api.openai.com/auth"]?.chatgpt_account_id || null;
  } catch {
    return null;
  }
}

function normalizeSummary(root = {}) {
  if (!root || (!Array.isArray(root.credits) && root.availableCount == null && root.available_count == null))
    throw new Error("官方权益数据缺少次数与明细");
  const credits = Array.isArray(root.credits)
    ? root.credits
        .map((credit) => ({
          title: credit.title || "Full reset",
          status: String(credit.status || "unknown"),
          resetType: credit.resetType || credit.reset_type || "unknown",
          grantedAt: decodeDate(credit.grantedAt ?? credit.granted_at),
          expiresAt: decodeDate(credit.expiresAt ?? credit.expires_at),
        }))
        .filter((credit) => credit.grantedAt)
    : null;
  const availableCredits = (credits || [])
    .filter((credit) => credit.status.toLowerCase() === "available")
    .sort(
      (a, b) =>
        Date.parse(a.expiresAt || "9999-12-31") -
          Date.parse(b.expiresAt || "9999-12-31") ||
        Date.parse(a.grantedAt) - Date.parse(b.grantedAt),
    );
  const count = Number(root.availableCount ?? root.available_count);
  const availableCount = Math.max(
    0,
    Number.isFinite(count) ? count : availableCredits.length,
  );
  return {
    availableCount,
    credits,
    availableCredits,
    missingDetailCount: Math.max(0, availableCount - availableCredits.length),
  };
}

class ResetCreditsSource {
  constructor({
    codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex"),
    fetcher = global.fetch,
    now = () => Date.now(),
  } = {}) {
    this.codexHome = codexHome;
    this.fetcher = fetcher;
    this.now = now;
    this.summary = null;
    this.cachedAt = 0;
    this.failedUntil = 0;
    this.inFlight = null;
    this.lastFailure = null;
  }

  async loadCredential() {
    const root = JSON.parse(
      await fsp.readFile(path.join(this.codexHome, "auth.json"), "utf8"),
    );
    const tokens = root.tokens || {};
    const accessToken = tokens.access_token || tokens.accessToken;
    if (!accessToken) throw new Error("missing_auth");
    return {
      accessToken,
      accountID:
        decodeJWTAccountID(accessToken) ||
        tokens.account_id ||
        tokens.accountId ||
        null,
    };
  }

  async current({ force = false } = {}) {
    const now = this.now();
    if (!force && this.summary && now - this.cachedAt <= 300_000)
      return this.summary;
    if (!force && now < this.failedUntil) return this.summary;
    if (this.inFlight) return this.inFlight;
    this.inFlight = this.fetchSummary()
      .then((summary) => {
        this.summary = summary;
        this.cachedAt = this.now();
        this.failedUntil = 0;
        this.lastFailure = null;
        return summary;
      })
      .catch((error) => {
        this.failedUntil = this.now() + 60_000;
        this.lastFailure = error.message;
        return this.summary;
      })
      .finally(() => {
        this.inFlight = null;
      });
    return this.inFlight;
  }

  async fetchSummary() {
    const credential = await this.loadCredential();
    const headers = {
      Authorization: `Bearer ${credential.accessToken}`,
      originator: "Codex Desktop",
      "OAI-Product-Sku": "CODEX",
      Accept: "application/json",
      "User-Agent": "codex-reset-credit-readonly/1.0",
    };
    if (credential.accountID)
      headers["ChatGPT-Account-Id"] = credential.accountID;
    const response = await this.fetcher(ENDPOINT, {
      headers,
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`http_${response.status}`);
    return normalizeSummary(await response.json());
  }
}

module.exports = {
  ResetCreditsSource,
  normalizeSummary,
  decodeJWTAccountID,
  decodeDate,
  ENDPOINT,
};
