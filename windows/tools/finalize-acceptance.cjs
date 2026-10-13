const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const stage = path.resolve(process.argv[2]);
const source = path.resolve(__dirname, '..');
const start = JSON.parse(fs.readFileSync(path.join(stage, 'test-results/acceptance-start.json'), 'utf8').replace(/^\uFEFF/, ''));
const log = path.join(start.Support, 'runtime-acceptance.jsonl');
const rows = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
const latest = rows.at(-1);
const cycles = [...new Set(rows.map(row => row.diagnostics.radar?.lastSuccessAt).filter(Boolean))].sort();
const manifest = JSON.parse(fs.readFileSync(path.join(stage, 'test-results/release-manifest.json')));
const expectedHash = manifest.source.find(file => file.path === 'main.js').sha256.slice(0, 16);
const gaps = rows.slice(1).map((row, i) => Date.parse(row.at) - Date.parse(rows[i].at));
const maxGapMs = Math.max(0, ...gaps);
const summary = {
  startedAt: start.Start, lastRecordAt: latest?.at,
  elapsedMinutes: (latest?.elapsedMs || 0) / 60000, samples: rows.length,
  successfulRadarReads: cycles.map(time => new Date(time).toISOString()),
  automaticRadarCycles: Math.max(0, cycles.length - 1), maxSampleGapMs: maxGapMs,
  sourceMatches: rows.every(row => row.sourceHash === expectedHash),
  freshLog: !!latest && Date.now() - Date.parse(latest.at) < 90000,
};
summary.ready = summary.elapsedMinutes >= 60 && summary.automaticRadarCycles >= 2 && summary.sourceMatches && summary.freshLog && maxGapMs < 90000;
if (!process.argv.includes('--finalize') || !summary.ready) {
  console.log(JSON.stringify(summary));
  if (process.argv.includes('--finalize')) process.exitCode = 2;
} else {
  finish().catch(error => { console.error(error); process.exitCode = 1; });
}
async function finish() {
  assert.ok(Number.isInteger(start.InspectorPort) && start.InspectorPort > 1024);
  const endpoint = 'http://127.0.0.1:' + start.InspectorPort + '/json/list';
  const targets = await (await fetch(endpoint, {signal:AbortSignal.timeout(5000)})).json();
  assert.ok(targets[0].webSocketDebuggerUrl.startsWith('ws://127.0.0.1:' + start.InspectorPort + '/'));
  const socket = new WebSocket(targets[0].webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, {once:true}); socket.addEventListener('error', reject, {once:true}); });
  let sequence = 0;
  function evaluate(expression) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timeout = setTimeout(() => { socket.removeEventListener('message', onMessage); reject(new Error('UI response timeout')); }, 10000);
      function onMessage(event) {
        const result = JSON.parse(event.data);
        if (result.id !== id) return;
        clearTimeout(timeout); socket.removeEventListener('message', onMessage);
        if (result.error || result.result?.exceptionDetails) reject(new Error('Inspector evaluation failed'));
        else resolve(result.result?.result?.value);
      }
      socket.addEventListener('message', onMessage);
      socket.send(JSON.stringify({ id, method:'Runtime.evaluate', params:{expression, returnByValue:true, awaitPromise:true} }));
    });
  }
  try {
    const identity = await evaluate('({pid:process.pid,exe:process.execPath})');
    assert.equal(identity.pid, start.PID);
    assert.equal(path.resolve(identity.exe).toLowerCase(), path.resolve(start.Executable).toLowerCase());
    const responses = [];
    for (let i = 0; i < 5; i++) {
      const then = performance.now();
      const windows = await evaluate("Promise.all(process.mainModule.require('electron').BrowserWindow.getAllWindows().map(w=>w.webContents.executeJavaScript('({title:document.title,ready:document.readyState})')))" );
      assert.ok(windows.length && windows.every(w => w.ready === 'complete'));
      responses.push(performance.now() - then);
    }
    const mib = bytes => Math.round(bytes / 1048576 * 10) / 10;
    const totals = rows.map(row => row.processes.reduce((sum, p) => sum + (p.memory?.workingSetSize || 0) * 1024, 0));
    const cpus = rows.map(row => row.processes.reduce((sum, p) => sum + (p.cpu?.percentCPUUsage || 0), 0));
    const report = { ...summary, completedAt:new Date().toISOString(), passed:true,
      mainRssMiB:{first:mib(rows[0].memory.rss),last:mib(latest.memory.rss),max:mib(Math.max(...rows.map(r=>r.memory.rss)))},
      allProcessWorkingSetMiB:{first:mib(totals[0]),last:mib(totals.at(-1)),max:mib(Math.max(...totals))},
      averageCombinedCpuPercent:cpus.reduce((a,b)=>a+b,0)/cpus.length,
      maxEventLoopDelayMs:Math.max(...rows.map(row=>row.delayMs)),
      rendererResponseMs:responses,
      healthAtEnd:latest.diagnostics.health,
      sourceStatesAtEnd:latest.diagnostics.sourceStates,
      failureEvents:[...new Set(rows.flatMap(row=>row.diagnostics.events.filter(e=>e.level==='failure').map(e=>JSON.stringify(e))))].map(s=>JSON.parse(s)),
      note:'Memory measurements include Electron processes and GPU; CPU values are periodic samples. Network failure/recovery was tested separately by isolated injection.'
    };
    assert.ok(report.healthAtEnd.every(item => item.state !== 'critical'), 'Critical health check at end of acceptance');
    assert.ok(report.maxEventLoopDelayMs < 10000, 'Main process was unresponsive during acceptance');
    assert.ok(Math.max(...responses) < 5000, 'Renderer response is too slow');
    const evidence = path.join(source, 'dist/validation-2.11.0');
    fs.writeFileSync(path.join(evidence, 'acceptance-report.json'), JSON.stringify(report, null, 2));
    fs.copyFileSync(log, path.join(evidence, 'runtime-acceptance.jsonl'));
    const section = '## 连续运行\n\n最终打包程序从 ' + start.Start + ' 连续运行至 ' + latest.at + '，实测 ' + summary.elapsedMinutes.toFixed(1) + ' 分钟，共 ' + rows.length + ' 条每分钟记录。启动后完成 ' + summary.automaticRadarCycles + ' 次雷达自动抓取；成功时间为 ' + summary.successfulRadarReads.join('、') + '。\n\n主进程 RSS：首次 ' + report.mainRssMiB.first + ' MiB，最后 ' + report.mainRssMiB.last + ' MiB，最大 ' + report.mainRssMiB.max + ' MiB；全部 Electron 进程工作集最后 ' + report.allProcessWorkingSetMiB.last + ' MiB。平均合计 CPU 采样 ' + report.averageCombinedCpuPercent.toFixed(2) + '%；最大主进程定时器延迟 ' + report.maxEventLoopDelayMs + ' ms。末尾五次显示页面响应均完成，最大往返 ' + Math.max(...responses).toFixed(1) + ' ms。\n\n使用独立数据目录、真实官方额度与公开雷达读取，禁用测试实例的 OneDrive 同步、更新检查和通知。运行失败事件 ' + report.failureEvents.length + ' 条。详细数据见 validation-2.11.0/acceptance-report.json 和 runtime-acceptance.jsonl；网络失败及恢复的隔离测试另见 network-validation/report.json。\n\n';
    const document = path.join(source, 'docs/VALIDATION_2.11.0.md');
    const content = fs.readFileSync(document, 'utf8').replace(/## 连续运行\n[\s\S]*?(?=## 尚未实机验证)/, section);
    fs.writeFileSync(document, content);
    fs.copyFileSync(document, path.join(source, 'dist/VALIDATION_2.11.0.md'));
    await evaluate("setTimeout(()=>process.mainModule.require('electron').app.quit(),100);true");
    console.log(JSON.stringify(report));
  } finally { socket.close(); }
}
