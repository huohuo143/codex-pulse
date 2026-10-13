const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

function slug(value) {
  return (
    value
      .toLowerCase()
      .replace(/\.local$/i, "")
      .replace(/[^\p{L}\p{N}]+/gu, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || "windows-pc"
  );
}

function normalizedSnapshot(value) {
  if (
    !value ||
    value.app !== "codex" ||
    ![2, 3, 4].includes(Number(value.schemaVersion))
  )
    return null;
  return {
    ...value,
    schemaVersion: Number(value.schemaVersion),
    daily: Array.isArray(value.daily) ? value.daily : [],
    monthly: Array.isArray(value.monthly) ? value.monthly : [],
    hourly: Array.isArray(value.hourly) ? value.hourly : [],
    modelHourly: Array.isArray(value.modelHourly) ? value.modelHourly : [],
  };
}

class OneDriveSync {
  constructor(root) {
    const oneDrive =
      root ||
      process.env.OneDriveCommercial ||
      process.env.OneDriveConsumer ||
      process.env.OneDrive;
    this.directory = oneDrive
      ? path.join(oneDrive, "算力码表", "设备统计")
      : null;
    this.deviceID = slug(os.hostname());
  }

  async persistAndRead(stats) {
    if (!this.directory) return [];
    await fs.mkdir(this.directory, { recursive: true });
    const host = os.hostname();
    const snapshot = {
      schemaVersion: 4,
      app: "codex",
      deviceID: this.deviceID,
      deviceName: host,
      hostName: host,
      updatedAt: new Date().toISOString(),
      todayTokens: stats.todayTokens,
      monthTokens: stats.monthTokens,
      sampleCount: stats.sampleCount,
      daily: stats.daily,
      monthly: stats.monthly,
      hourly: stats.hourly,
      modelHourly: stats.modelHourly || [],
    };
    const target = path.join(
      this.directory,
      `${snapshot.deviceID}-codex-v2.json`,
    );
    const temporary = `${target}.tmp`;
    await fs.writeFile(temporary, JSON.stringify(snapshot, null, 2));
    await fs.rename(temporary, target).catch(async () => {
      await fs.copyFile(temporary, target);
      await fs.unlink(temporary).catch(() => {});
    });

    const names = await fs.readdir(this.directory);
    const candidates = [];
    for (const name of names.filter((item) =>
      /-codex(?:-v2)?\.json$/i.test(item),
    )) {
      try {
        const value = normalizedSnapshot(
          JSON.parse(
            await fs.readFile(path.join(this.directory, name), "utf8"),
          ),
        );
        if (value)
          candidates.push({
            value,
            isV2: /-codex-v2\.json$/i.test(name),
            isLocal: value.deviceID === this.deviceID,
          });
      } catch {
        /* syncing or damaged file */
      }
    }
    const chosen = new Map();
    for (const candidate of candidates.sort((a, b) => {
      if (a.isLocal !== b.isLocal) return a.isLocal ? -1 : 1;
      if (a.isV2 !== b.isV2) return a.isV2 ? -1 : 1;
      return (
        Date.parse(b.value.updatedAt || 0) - Date.parse(a.value.updatedAt || 0)
      );
    }))
      if (!chosen.has(candidate.value.deviceID))
        chosen.set(candidate.value.deviceID, candidate.value);
    const local = chosen.get(this.deviceID);
    chosen.delete(this.deviceID);
    return [
      ...(local ? [local] : []),
      ...[...chosen.values()].sort(
        (a, b) => Date.parse(b.updatedAt || 0) - Date.parse(a.updatedAt || 0),
      ),
    ];
  }
}

module.exports = { OneDriveSync, slug, normalizedSnapshot };
