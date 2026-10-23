function retryAfter(value, now) {
  if (!value) return 0;
  if (/^\s*\d+(?:\.\d+)?\s*$/.test(value)) return now + Number(value) * 1000;
  return Math.max(now, Date.parse(value) || 0);
}
async function request(fetcher, url, { type = "html", timeout = 30000, attempts = 3, now = () => Date.now(), headers = {}, sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  const deadline = Date.now() + timeout;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const left = deadline - Date.now();
    if (left <= 0) throw new Error("公开源请求超时");
    const controller = new AbortController();
    let timer;
    try {
      return await Promise.race([
        (async () => {
          const response = await fetcher(url, { headers: { Accept: type === "json" ? "application/json" : "text/html", ...headers }, signal: controller.signal });
          if (!response.ok) {
            const e = new Error("公开源 HTTP " + response.status);
            e.transient = [408, 425, 500, 502, 503, 504].includes(response.status);
            e.retryAt = retryAfter(response.headers?.get?.("retry-after"), now());
            if (response.status === 429 && !e.retryAt) e.retryAt = now() + 60000;
            throw e;
          }
          return type === "json" ? await response.json() : await response.text();
        })(),
        new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); const e = new Error("公开源请求超时"); e.transient = true; reject(e); }, left); }),
      ]);
    } catch (e) {
      if (e.retryAt || e.transient === false || (e.message?.startsWith("公开源 HTTP") && !e.transient) || attempt === attempts - 1 || Date.now() >= deadline) throw e;
      await sleep(Math.min([300, 900][attempt] || 900, Math.max(0, deadline - Date.now())));
    } finally { clearTimeout(timer); }
  }
}
module.exports = { request, retryAfter };
