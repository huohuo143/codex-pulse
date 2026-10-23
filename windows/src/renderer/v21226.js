const calendarTab = document.createElement('button'); calendarTab.dataset.section = 'calendar'; calendarTab.textContent = '重置日历';
$('.segmented-control [data-section="settings"]').before(calendarTab);
calendarTab.onclick = () => showSection('calendar');
const calendarPanel = document.createElement('section'); calendarPanel.className = 'dashboard-section'; calendarPanel.dataset.panel = 'calendar';
calendarPanel.innerHTML = '<article class="card reset-calendar"><div class="calendar-toolbar"><div><h2>重置日历</h2><p>北京时间 · 已确认的历史事件</p></div><div class="button-row"><button id="calendarPrevious" aria-label="上个月">‹</button><strong id="calendarMonth"></strong><button id="calendarNext" aria-label="下个月">›</button><button id="calendarToday">本月</button></div></div><div class="calendar-toolbar"><select id="calendarKind" aria-label="事件类型"><option value="all">全部事件</option><option value="hardReset">硬重置</option><option value="resetCard">重置卡</option></select><span id="calendarCounts"></span></div><div id="calendarGrid" class="calendar-grid" role="group" aria-label="北京时间重置月历"></div><p id="calendarTotals" class="record-feedback"></p><div id="calendarDetails" aria-live="polite"></div><p class="calendar-note">空白日期不代表一定未发生重置。只有月度总数的记录单列，不分配到具体日期。确认时间、原帖时间与实际到账时间分别标注。</p><p id="calendarSync" class="calendar-note"></p><p id="calendarAttribution" class="calendar-note"></p></article>';
$('[data-panel="settings"]').before(calendarPanel);
const recordCard = document.createElement('article'); recordCard.className = 'card settings-card';
recordCard.innerHTML = '<h3>记录保护与恢复</h3><p>异常记录保留原件并停止写入。恢复前保存损坏原件，编辑中的草稿保留。</p><div id="recordHealth"></div><button id="openRecords">打开记录文件夹</button>';
$('#newSettings').append(recordCard); $('#openRecords').onclick = () => window.suanli.openRecords();
const protectionBanner = document.createElement('p'); protectionBanner.className = 'record-feedback protection-banner'; protectionBanner.setAttribute('role', 'status'); overviewPanel.prepend(protectionBanner);
const compactClock = document.createElement('div'); compactClock.className = 'compact-reset-clock'; compactClock.innerHTML = '<strong data-bind="radarMicro">等待动态</strong><span data-bind="radarClock"></span>'; $('.compact-view').append(compactClock);
const clock = document.createElement('p'); clock.className = 'reset-clock'; clock.dataset.bind = 'radarClock'; $('.radar-main [data-bind="radarSummary"]').before(clock);
$('#brierScore').closest('article').hidden = true;
const todayBJ = () => new Date(Date.now() + 8 * 3600000).toISOString().slice(0, 10);
let calendarMonth = todayBJ().slice(0, 7), calendarDay = todayBJ(), calendarState = null, calendarSignature = '', recordSignature = '';
function changeMonth(delta) { const at = new Date(calendarMonth + '-01T00:00:00Z'); at.setUTCMonth(at.getUTCMonth() + delta); calendarMonth = at.toISOString().slice(0, 7); calendarDay = calendarMonth + '-01'; renderCalendar(true); }
$('#calendarPrevious').onclick = () => changeMonth(-1); $('#calendarNext').onclick = () => changeMonth(1);
$('#calendarToday').onclick = () => { calendarMonth = todayBJ().slice(0, 7); calendarDay = todayBJ(); renderCalendar(true); };
$('#calendarKind').onchange = () => renderCalendar(true);
function renderCalendar(force = false) {
  if (!calendarState) return;
  const kind = $('#calendarKind').value, signature = JSON.stringify(calendarState) + calendarMonth + calendarDay + kind;
  if (!force && calendarSignature === signature) return; calendarSignature = signature;
  const events = (calendarState.events || []).filter(e => e.day.startsWith(calendarMonth) && (kind === 'all' || e.kind === kind));
  $('#calendarMonth').textContent = calendarMonth.replace('-', ' 年 ') + ' 月';
  $('#calendarCounts').textContent = `${events.filter(e => e.kind === 'hardReset').length} 次硬重置 · ${events.filter(e => e.kind === 'resetCard').length} 批重置卡`;
  const grid = $('#calendarGrid'); grid.replaceChildren();
  for (const name of ['一', '二', '三', '四', '五', '六', '日']) { const el = document.createElement('span'); el.className = 'calendar-weekday'; el.textContent = name; grid.append(el); }
  const start = new Date(calendarMonth + '-01T00:00:00Z'), offset = (start.getUTCDay() + 6) % 7, count = new Date(start.getUTCFullYear(), start.getUTCMonth() + 1, 0).getDate();
  for (let i = 0; i < offset; i++) grid.append(document.createElement('span'));
  for (let i = 1; i <= count; i++) {
    const day = calendarMonth + '-' + String(i).padStart(2, '0'), rows = events.filter(e => e.day === day), button = document.createElement('button');
    button.className = 'calendar-day'; button.classList.toggle('today', day === todayBJ()); button.classList.toggle('selected', day === calendarDay);
    button.setAttribute('aria-pressed', String(day === calendarDay)); button.setAttribute('aria-label', day + `，${rows.length} 条已确认事件`);
    const label = document.createElement('b'); label.textContent = i; button.append(label);
    for (const k of ['hardReset', 'resetCard']) { const n = rows.filter(e => e.kind === k).length; if (n) { const badge = document.createElement('small'); badge.className = k; badge.textContent = (k === 'hardReset' ? '重置 ' : '发卡 ') + n; button.append(badge); } }
    button.onclick = () => { calendarDay = day; renderCalendar(true); }; grid.append(button);
  }
  const totals = calendarState.monthlyTotals?.find(r => r.month === calendarMonth);
  $('#calendarTotals').textContent = totals ? `公开源原始月度总数：${totals.hardResets} 次硬重置、${totals.resetCards} 批重置卡；多来源覆盖口径可能不同。` : '当前来源未提供本月独立总数';
  const details = $('#calendarDetails'); details.replaceChildren();
  for (const event of events.filter(e => e.day === calendarDay)) {
    const article = document.createElement('article'); article.className = 'calendar-event';
    const title = document.createElement('h3'); title.textContent = `${event.kind === 'hardReset' ? '硬重置' : '重置卡'} · ${event.title}`;
    const summary = document.createElement('p'); summary.textContent = event.summary;
    const meta = document.createElement('p'); meta.className = 'calendar-note';
    const time = v => v ? RadarDisplay.beijing(v) : '未公布';
    meta.textContent = `${event.day} · ${{ official: '官方完成确认', community: '站长根据社区反馈确认', publicArchive: '公开历史记录，未独立核验官方原帖' }[event.confirmation] || '公开历史记录'}\n实际发生：${time(event.occurredAt)} · 确认：${time(event.confirmedAt)} · 原帖：${time(event.publishedAt)}${event.usesConfirmationDate ? '\n按确认日期归日，不代表逐户到账时刻' : ''}`;
    article.append(title, summary, meta);
    for (const [key, label] of [['announcementURL', '预告原帖'], ['completionURL', '完成确认'], ['publicationURL', '公开原帖'], ['sourceURL', '历史来源'], ['evidenceURL', '佐证来源']]) if (event[key]) {
      const link = document.createElement('button'); link.textContent = label + ' ↗'; link.onclick = () => window.suanli.openExternal(event[key]); article.append(link);
    }
    details.append(article);
  }
  if (!details.children.length) details.textContent = calendarDay + ' 暂无已收录的确认事件';
  $('#calendarSync').textContent = calendarState.error || (calendarState.lastSuccessAt ? '上次同步：' + RadarDisplay.beijing(calendarState.lastSuccessAt) : '随应用附带离线历史；尚未成功联网同步');
  $('#calendarAttribution').textContent = calendarState.attribution || '';
}
function renderRecordHealth(next) {
  const records = next.recordHealth || {}, signature = JSON.stringify(records);
  protectionBanner.textContent = Object.values(records).filter(r => r.state === 'warning' || r.state === 'critical').map(r => r.message).join('；'); protectionBanner.hidden = !protectionBanner.textContent;
  if (recordSignature === signature) return; recordSignature = signature;
  const target = $('#recordHealth'); target.replaceChildren();
  const labels = { 'project-budgets-v1': '项目预算', 'credit-expiry-batches-v1': '分批额度记录', 'credit-expiry-v1': '原单笔额度记录' };
  for (const [name, health] of Object.entries(records)) {
    const row = document.createElement('div'); row.className = 'record-health';
    const label = document.createElement('p'); label.textContent = (labels[name] || '当前账户额度历史') + ' · ' + health.message; row.append(label);
    for (const [action, title] of [['reload', '重新读取'], ['restore', '恢复上次有效记录']]) { const button = document.createElement('button'); button.textContent = title; button.onclick = async () => {
      button.disabled = true;
      try { const result = await window.suanli.recordAction({ name, action }); showToast(result.message); }
      catch (error) { showToast(ErrorMessages.readable(error, '记录操作失败'), 'error'); }
      finally { button.disabled = false; }
    }; row.append(button); }
    target.append(row);
  }
}
function renderLatest(next) { calendarState = next.resetCalendar || next.radar?.calendar || calendarState; renderCalendar(); renderRecordHealth(next); }
window.suanli.onStatus(renderLatest);
if (status) renderLatest(status);
document.addEventListener('keydown', e => { if (e.ctrlKey && e.key === '4') { e.preventDefault(); showSection('calendar'); } });
setInterval(() => { if (radar) { const display = RadarDisplay.clock(radar); setAll('radarClock', display.detail); setAll('radarProbability', display.title); setAll('radarMicro', display.title); } }, 1000);
if (settings.selectedSection === 'calendar') showSection('calendar', false);
