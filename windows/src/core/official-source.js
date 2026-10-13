const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { createHash } = require("node:crypto");
const { fetchLiveRateLimits, payloadToEvents } = require("./codex-app-server");
const { selectSevenDayWindow } = require("./codex-reader");
const { ResetCreditsSource, normalizeSummary } = require("./reset-credits");
const { succeed, fail, visible, freshness } = require("./data-freshness");
async function accountScope(home) {
  try {
    const auth = JSON.parse(
      await fs.readFile(path.join(home, "auth.json"), "utf8"),
    );
    const t = auth.tokens || {};
    let id = t.account_id || t.accountId;
    if (!id && t.access_token) {
      try {
        id = JSON.parse(Buffer.from(t.access_token.split(".")[1], "base64url"))[
          "https://api.openai.com/auth"
        ]?.chatgpt_account_id;
      } catch {}
    }
    return id
      ? createHash("sha256")
          .update("codex-pulse-account:" + id)
          .digest("hex")
          .slice(0, 24)
      : null;
  } catch {
    return null;
  }
}
class OfficialSource {
  constructor({
    home = process.env.CODEX_HOME || path.join(os.homedir(), ".codex"),
    fetchLive = fetchLiveRateLimits,
    credits = new ResetCreditsSource({ codexHome: home }),
  } = {}) {
    this.home = home;
    this.fetchLive = fetchLive;
    this.credits = credits;
    this.scope = null;
    this.state = {};
    this.pending = null;
  }
  async read({ force = false } = {}) {
    if (this.pending) return this.pending;
    this.pending = this.perform(force).finally(() => (this.pending = null));
    return this.pending;
  }
  async perform(force) {
    const scope = await accountScope(this.home);
    if (scope !== this.scope) {
      this.scope = scope;
      this.state = {};
      this.credits.summary = null;
      this.credits.cachedAt = 0;
      this.credits.failedUntil = 0;
    }
    const started = Date.now();
    const results = await Promise.allSettled([
      this.fetchLive({ raw: true }),
      this.credits.current({ force }),
    ]);
    // An account switch during a request invalidates both responses.
    if ((await accountScope(this.home)) !== scope) {
      this.state = {};
      return this.snapshot();
    }
    const now = Date.now();
    const live = results[0];
    let liveReset = null;
    if (live.status === "fulfilled") {
      const raw = live.value;
      if (raw.rateLimitResetCredits)
        liveReset = normalizeSummary(raw.rateLimitResetCredits);
      const events = payloadToEvents(raw),
        main = events.find((e) => e.limitID === "codex") || events[0],
        weekly = selectSevenDayWindow(main),
        fiveHour =
          [main?.primary, main?.secondary].find(
            (w) => w && Math.abs(w.windowMinutes - 300) <= 5,
          ) || null;
      if (weekly || fiveHour) {
        Object.assign(this.state, {
          main,
          weekly,
          fiveHour,
          quotaRead: succeed(
            "Codex app-server",
            now,
            new Date(started).toISOString(),
          ),
        });
      } else
        this.state.quotaRead = fail(
          this.state.quotaRead,
          now,
          "官方窗口暂不可用",
        );
      const credits = (raw.rateLimitsByLimitId?.codex || raw.rateLimits)
        ?.credits;
      if (credits && typeof credits === "object") {
        const amount =
          credits.balance === null || credits.balance === undefined
            ? null
            : Number(credits.balance);
        this.state.flexible = {
          hasCredits: credits.hasCredits === true,
          unlimited: credits.unlimited === true,
          balanceCredits:
            Number.isFinite(amount) && amount >= 0 ? amount : null,
          amountUSD:
            Number.isFinite(amount) && amount >= 0 ? amount / 25 : null,
        };
        this.state.flexibleRead = succeed(
          "Codex app-server",
          now,
          new Date(started).toISOString(),
        );
      } else
        this.state.flexibleRead = fail(
          this.state.flexibleRead,
          now,
          "官方余额暂不可用",
        );
    } else {
      this.state.quotaRead = fail(
        this.state.quotaRead,
        now,
        "官方额度读取失败",
      );
      this.state.flexibleRead = fail(
        this.state.flexibleRead,
        now,
        "官方余额读取失败",
      );
    }
    const credits = results[1];
    if (credits.status === "fulfilled" && credits.value) {
      this.state.rateLimitResetCredits = credits.value;
      const sampled = new Date(this.credits.cachedAt).toISOString();
      this.state.resetRead = {
        source: "官方 Full reset",
        sampledAt: sampled,
        lastSuccessAt: sampled,
        lastAttemptAt: new Date(now).toISOString(),
        failure: this.credits.lastFailure ? "官方权益读取失败" : null,
      };
    } else
      this.state.resetRead = fail(
        this.state.resetRead,
        now,
        "官方权益暂不可用",
      );
    if (liveReset) {
      this.state.rateLimitResetCredits = liveReset;
      this.state.resetRead = succeed(
        "Codex app-server",
        now,
        new Date(started).toISOString(),
      );
    }
    return this.snapshot();
  }
  snapshot(now = Date.now()) {
    const s = this.state;
    return {
      accountScope: this.scope,
      main: s.main || null,
      weekly: visible(s.quotaRead, now, s.weekly?.resetsAt) ? s.weekly : null,
      fiveHour: visible(s.quotaRead, now, s.fiveHour?.resetsAt)
        ? s.fiveHour
        : null,
      flexible: visible(s.flexibleRead, now) ? s.flexible : null,
      rateLimitResetCredits: visible(s.resetRead, now)
        ? s.rateLimitResetCredits
        : null,
      quotaRead: s.quotaRead,
      flexibleRead: s.flexibleRead,
      resetRead: s.resetRead,
      sourceStates: {
        quota: s.weekly
          ? freshness(s.quotaRead, now, s.weekly.resetsAt)
          : "unavailable",
        fiveHour: s.fiveHour
          ? freshness(s.quotaRead, now, s.fiveHour.resetsAt)
          : "unavailable",
        flexible: freshness(s.flexibleRead, now),
        reset: freshness(s.resetRead, now),
      },
    };
  }
}
module.exports = { OfficialSource, accountScope };
