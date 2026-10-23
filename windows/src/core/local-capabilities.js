const { spawn } = require('node:child_process');
const { codexCandidates } = require('./codex-app-server');
const MODEL = /^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,199}$/;
async function inspect() {
  const command = codexCandidates().find(p => /\.exe$/i.test(p));
  if (!command) throw new Error('未找到本机 Codex，请先安装并登录');
  return new Promise((resolve, reject) => {
    const child = spawn(command, ['app-server', '--listen', 'stdio://'], { windowsHide: true, shell: false, stdio: ['pipe', 'pipe', 'ignore'] });
    let buffer = '', settled = false, id = 2, accountType, models = [], cursors = new Set();
    const finish = (error, value) => { if (settled) return; settled = true; clearTimeout(timer); child.kill(); error ? reject(error) : resolve(value); };
    const timer = setTimeout(() => finish(new Error('本机登录与模型检测超时，请打开 Codex 后重试')), 20000);
    const send = (method, params, requestID) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params, ...(requestID ? { id: requestID } : {}) }) + '\n');
    child.on('error', () => finish(new Error('本机 Codex 启动失败')));
    child.on('exit', () => { if (!settled) finish(new Error('本机 Codex 连接已结束')); });
    child.stdin.on('error', () => finish(new Error('本机 Codex 连接已关闭')));
    child.stdout.on('data', chunk => {
      buffer += chunk; if (buffer.length > 2000000) return finish(new Error('模型列表超过上限'));
      while (buffer.includes('\n')) {
        const n = buffer.indexOf('\n'), line = buffer.slice(0, n); buffer = buffer.slice(n + 1);
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (!m.id) continue;
        if (m.error) return finish(new Error('无法读取本机登录或模型列表，请更新 Codex 后重试'));
        if (m.id === 1) { send('initialized'); send('account/read', { refreshToken: false }, 2); }
        else if (m.id === 2) {
          accountType = m.result?.account?.type;
          if (!accountType) return finish(null, { installed: true, signedIn: false, models: [] });
          send('model/list', { limit: 100 }, ++id);
        } else if (m.id === id) {
          models.push(...(m.result?.data || []).filter(x => !x.hidden && MODEL.test(x.model)).map(x => ({ model: x.model, displayName: x.displayName, isDefault: x.isDefault, defaultReasoningEffort: x.defaultReasoningEffort, supportedReasoningEfforts: x.supportedReasoningEfforts })));
          const cursor = m.result?.nextCursor;
          if (cursor) { if (cursors.has(cursor) || cursors.size >= 20) return finish(new Error('模型分页异常')); cursors.add(cursor); send('model/list', { limit: 100, cursor }, ++id); }
          else finish(null, { installed: true, signedIn: ['chatgpt', 'apiKey'].includes(accountType), accountType, models: [...new Map(models.map(m => [m.model, m])).values()] });
        }
      }
    });
    send('initialize', { clientInfo: { name: 'CodexPulseCapabilities', version: '2.12.29' } }, 1);
  });
}
function selection(preferences, capabilities) {
  if (!capabilities.signedIn) throw new Error('请先在本机 Codex 登录自己的账号');
  const model = preferences.model ? capabilities.models.find(m => m.model === preferences.model) : capabilities.models.find(m => m.isDefault) || capabilities.models[0];
  if (!model) throw new Error('当前账号不支持所选模型，请在设置中重新检测并选择');
  const effort = preferences.effort === 'auto' ? model.defaultReasoningEffort : preferences.effort;
  if (!model.supportedReasoningEfforts?.some(e => e.reasoningEffort === effort)) throw new Error('当前模型不支持所选推理强度，请选择模型默认');
  return { model: model.model, effort };
}
function preferences(store) {
  const previous = store?.read('radar-announcements-v2', {})?.analysis;
  return store?.read('tibo-preferences-v1', null) || { enabled: !!previous?.model, model: previous?.model || '', effort: previous?.reasoningEffort || 'auto', source: 'public' };
}
function save(store, value) {
  if (!value || typeof value.enabled !== 'boolean' || typeof value.model !== 'string' || value.model && !MODEL.test(value.model) || !['auto','none','minimal','low','medium','high','xhigh','max','ultra'].includes(value.effort) || !['public','x'].includes(value.source)) throw new Error('分析设置无效');
  const clean = { enabled: value.enabled, model: value.model, effort: value.effort, source: value.source }; store.write('tibo-preferences-v1', clean); return clean;
}
module.exports = { inspect, selection, preferences, save };
