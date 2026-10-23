const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { codexCandidates } = require('./codex-app-server');
const DAY = 86400000;
const MODEL = 'gpt-6-astra';
const EFFORT = 'high';

function retained(posts, now) {
  return (posts || []).filter(p => Date.parse(p.publishedAt) >= now - 7 * DAY && Date.parse(p.publishedAt) <= now + 3600000);
}
function localParts(at, zone) {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(at));
  const get = k => Number(parts.find(p => p.type === k).value);
  return Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second'));
}
function zoneOffset(zone) {
  const fixed = { PST: -480, PDT: -420, UTC: 0, GMT: 0, BJT: 480, '北京时间': 480 };
  if (zone.toUpperCase() in fixed) return fixed[zone.toUpperCase()];
  const m = zone.match(/^(?:UTC|GMT)?([+-])(\d{2}):(\d{2})$/i);
  if (m && +m[2] <= 14 && +m[3] < 60 && (+m[2] < 14 || +m[3] === 0)) return (m[1] === '-' ? -1 : 1) * (+m[2] * 60 + +m[3]);
  return null;
}
function deadlineDate(deadline) {
  if (!deadline || typeof deadline.localDateTime !== 'string' || typeof deadline.sourceTimeZone !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/.test(deadline.localDateTime)) return null;
  const local = Date.parse(deadline.localDateTime + 'Z');
  if (!Number.isFinite(local) || new Date(local).toISOString().slice(0, 19) !== deadline.localDateTime) return null;
  const fixed = zoneOffset(deadline.sourceTimeZone);
  if (fixed !== null) return local - fixed * 60000;
  const zone = /^(?:PT|Pacific Time)$/i.test(deadline.sourceTimeZone) ? 'America/Los_Angeles' : deadline.sourceTimeZone;
  if (!zone.includes('/')) return null;
  try {
    // Enumerating offsets on both sides of a DST transition rejects skipped and repeated hours.
    const offsets = new Set([-2, -1, 0, 1, 2].map(d => localParts(local + d * DAY, zone) - (local + d * DAY)));
    const candidates = [...offsets].map(offset => local - offset).filter(at => localParts(at, zone) === local);
    return candidates.length === 1 ? candidates[0] : null;
  } catch { return null; }
}
function groundedDeadline(deadline, post) {
  const at = deadlineDate(deadline);
  if (at === null || !post || deadline.evidenceID !== post.id || typeof deadline.sourceQuote !== 'string' || !deadline.sourceQuote || deadline.sourceQuote.length > 1500 || !post.originalText.includes(deadline.sourceQuote) || at < Date.parse(post.publishedAt)) return false;
  const escaped = deadline.sourceTimeZone.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  if (!new RegExp('(?<![A-Za-z])' + escaped + '(?![A-Za-z])', 'i').test(deadline.sourceQuote)) return false;
  const fixed = zoneOffset(deadline.sourceTimeZone);
  const zone = /^(PT|Pacific Time)$/i.test(deadline.sourceTimeZone) ? 'America/Los_Angeles' : deadline.sourceTimeZone;
  const day = t => Math.floor((fixed === null ? localParts(t, zone) : t + fixed * 60000) / DAY);
  for (const [word, offset] of [['today', 0], ['tomorrow', 1]])
    if (new RegExp('\\b' + word + '\\b', 'i').test(deadline.sourceQuote) && day(at) !== day(Date.parse(post.publishedAt)) + offset) return false;
  return true;
}
function validate(result, posts, now) {
  const invalid = () => { throw new Error('模型返回的格式或原帖依据无效，未采用该结论'); };
  if (!result || !['announced', 'completed', 'not_found', 'uncertain'].includes(result.state) || !['hard_reset', 'reset_card', 'none', 'uncertain'].includes(result.kind) || typeof result.summaryZh !== 'string' || !result.summaryZh.trim() || result.summaryZh.length > 1000 || typeof result.timingZh !== 'string' || result.timingZh.length > 500 || !Array.isArray(result.evidenceIDs) || result.evidenceIDs.length > 10) invalid();
  const valid = retained(posts, now).filter(p => p.originalText);
  if (!result.evidenceIDs.every(id => valid.some(p => p.id === id))) invalid();
  if (['announced', 'completed'].includes(result.state) && (!result.evidenceIDs.length || !['hard_reset', 'reset_card'].includes(result.kind))) invalid();
  if (result.deadline && (result.state !== 'announced' || !result.evidenceIDs.includes(result.deadline.evidenceID) || !groundedDeadline(result.deadline, valid.find(p => p.id === result.deadline.evidenceID)))) invalid();
  let completedAt = null;
  if (result.state === 'completed') {
    const post = valid.find(p => p.id === result.completionEvidenceID);
    if (!post || !result.evidenceIDs.includes(post.id) || Date.parse(post.publishedAt) > now) invalid();
    completedAt = post.publishedAt;
  } else if (result.completionEvidenceID != null) invalid();
  return { state: result.state, kind: result.kind, summaryZh: result.summaryZh, timingZh: result.timingZh, evidenceIDs: result.evidenceIDs,
    deadline: result.deadline || null, completionEvidenceID: result.completionEvidenceID || null, completedAt,
    analyzedAt: new Date(now).toISOString(), model: MODEL, reasoningEffort: EFFORT };
}
function prompt(posts, now) {
  const items = retained(posts, now).filter(p => p.originalText).map(({ id, url, publishedAt, originalText, threadContext = '' }) => ({ id, url, publishedAt, originalText, threadContext }));
  const data = JSON.stringify(items);
  if (Buffer.byteLength(data) > 250000) throw new Error('本次公开动态过多，未提交不完整分析');
  return fs.readFileSync(path.join(__dirname, 'resources/tibo-prompt.txt'), 'utf8').replace('{{NOW}}', new Date(now).toISOString()).replace('{{POSTS}}', data);
}
async function analyze(posts, now = Date.now(), { timeout = 180000, signal } = {}) {
  const input = prompt(posts, now);
  const command = codexCandidates().find(p => /\.exe$/i.test(p) && fs.existsSync(p));
  if (!command) throw new Error('找不到本机 Codex 可执行程序，无法使用 GPT-6 Astra 分析');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'CodexPulse-Tibo-'));
  // The external Codex process cannot resolve Electron's virtual ASAR paths.
  const output = path.join(dir, 'result.json'), schema = path.join(dir, 'schema.json');
  const args = ['exec', '--ignore-user-config', '--ephemeral', '--skip-git-repo-check', '-s', 'read-only', '-C', dir, '-m', MODEL,
    '-c', 'model_reasoning_effort="high"', '-c', 'web_search="disabled"', '--enable', 'skip_host_skill_discovery'];
  for (const name of ['shell_tool', 'unified_exec', 'apps', 'browser_use', 'computer_use', 'in_app_browser', 'multi_agent', 'memories', 'hooks', 'image_generation', 'view_image', 'workspace_dependencies', 'goals', 'artifact']) args.push('--disable', name);
  args.push('--output-schema', schema, '--output-last-message', output, '--json', '-');
  try {
    fs.writeFileSync(schema, fs.readFileSync(path.join(__dirname, 'resources/tibo-schema.json')), { flag: 'wx', mode: 0o600 });
    await new Promise((resolve, reject) => {
      if (signal?.aborted) return reject(new Error('分析已取消'));
      const child = spawn(command, args, { cwd: dir, windowsHide: true, shell: false, stdio: ['pipe', 'ignore', 'ignore'] });
      let timedOut = false;
      const abort = () => child.kill();
      signal?.addEventListener('abort', abort, { once: true });
      const timer = setTimeout(() => { timedOut = true; child.kill(); }, timeout);
      child.once('error', () => { clearTimeout(timer); signal?.removeEventListener('abort', abort); reject(new Error('Codex 分析进程启动失败')); });
      child.once('close', code => { clearTimeout(timer); signal?.removeEventListener('abort', abort); code === 0 && !timedOut && !signal?.aborted ? resolve() : reject(new Error(timedOut ? 'GPT-6 Astra · High 分析超时，下一轮再试' : 'GPT-6 Astra · High 分析未完成，请检查 Codex 登录及模型权限')); });
      child.stdin.on('error', () => {});
      child.stdin.end(input);
    });
    if (fs.statSync(output).size > 32768) throw new Error('模型输出超过上限');
    return validate(JSON.parse(fs.readFileSync(output, 'utf8')), posts, Date.now());
  } finally { if (path.dirname(dir) === path.resolve(os.tmpdir())) fs.rmSync(dir, { recursive: true, force: true }); }
}

function latestConfirmedAt(snapshots, now) {
  const rows = (snapshots || []).filter(r => Date.parse(r.recordedAt) >= now - 7 * DAY && Date.parse(r.recordedAt) <= now && r.windowMinutes === 10080 && Number.isFinite(r.remainingPercent) && r.remainingPercent >= 0 && r.remainingPercent <= 100 && Date.parse(r.resetsAt) > Date.parse(r.recordedAt)).sort((a, b) => Date.parse(a.recordedAt) - Date.parse(b.recordedAt));
  let confirmed = null;
  for (let i = 1; i < rows.length; i++) {
    const a = rows[i - 1], b = rows[i], at = Date.parse(b.recordedAt), gap = at - Date.parse(a.recordedAt);
    if (gap > 0 && gap <= 1800000 && b.remainingPercent >= 90 && b.remainingPercent - a.remainingPercent >= 1 && Date.parse(a.resetsAt) > at + 300000 && Date.parse(b.resetsAt) - Date.parse(a.resetsAt) > 300000 && Math.abs(Date.parse(b.resetsAt) - 7 * DAY - at) <= 600000) confirmed = b.recordedAt;
  }
  return confirmed;
}
function presentation(snapshot, history, now) {
  const analysis = snapshot.analysis, local = Date.parse(latestConfirmedAt(history, now)), official = analysis?.state === 'completed' ? Date.parse(analysis.completedAt) : NaN;
  const preferOfficial = Number.isFinite(local) && official > local + DAY;
  let completed = preferOfficial ? official : Number.isFinite(local) ? local : official;
  const newest = Math.max(-Infinity, ...(snapshot.posts || []).filter(p => analysis?.evidenceIDs?.includes(p.id) && Date.parse(p.publishedAt) <= now).map(p => Date.parse(p.publishedAt)));
  if (analysis?.state === 'announced' && newest > completed) completed = NaN;
  const healthy = snapshot.refreshHealthy && now < snapshot.lastSuccessAt + 660000;
  let title, summary, completionUntil = null, deadline = null;
  if (Number.isFinite(completed) && completed <= now) {
    completionUntil = now < completed + DAY ? new Date(completed + DAY).toISOString() : null;
    title = completionUntil ? (!Number.isFinite(local) || preferOfficial) && analysis?.kind === 'reset_card' ? '重置卡已到账' : '已完成重置' : '等待新预告';
    summary = completionUntil ? Number.isFinite(local) && !preferOfficial ? '本账号官方额度已恢复，周额度周期已重新开始。从首次检测到账展示 24 小时；仅代表当前账号。' : analysis?.summaryZh || '已有完成确认' : '上一轮到账确认已展示 24 小时，继续检查新的重置预告。';
  } else if (healthy && analysis) {
    title = { announced: analysis.kind === 'reset_card' ? '发卡已预告' : '重置已预告', completed: '已有完成确认', not_found: '未发现新预告', uncertain: '尚不能确认' }[analysis.state];
    summary = analysis.summaryZh;
    if (analysis.state === 'announced' && analysis.deadline) {
      const at = deadlineDate(analysis.deadline);
      if (at !== null) deadline = { ...analysis.deadline, at: new Date(at).toISOString() };
    }
  } else {
    title = !snapshot.lastSuccessAt ? '等待动态' : now >= snapshot.lastSuccessAt + 660000 ? '动态已过期' : snapshot.error ? '动态未更新' : snapshot.analysisError ? '分析未成功' : '等待分析';
    summary = snapshot.error || snapshot.analysisError || '等待 GPT-6 Astra · High 完成本轮发帖与回复分析';
  }
  return { ...snapshot, latestLevelLabel: title, latestSummary: summary, deadline, completionUntil, completedAt: Number.isFinite(completed) ? new Date(completed).toISOString() : null, localCompletion: Number.isFinite(local) && !preferOfficial, refreshHealthy: !!healthy, prediction: null };
}
module.exports = { MODEL, EFFORT, retained, deadlineDate, groundedDeadline, validate, prompt, analyze, latestConfirmedAt, presentation };
