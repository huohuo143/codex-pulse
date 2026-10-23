const { BrowserWindow, session } = require('electron');
const URL_SOURCE = 'https://x.com/thsottiaux/with_replies';
const allowed = value => { try { const u = new URL(value); return u.protocol === 'https:' && /(^|\.)(x|twitter)\.com$/.test(u.hostname); } catch { return false; } };
class XSource {
  window() {
    if (this.win && !this.win.isDestroyed()) return this.win;
    const partition = 'persist:codex-pulse-x';
    session.fromPartition(partition).setPermissionRequestHandler((_, __, cb) => cb(false));
    const win = this.win = new BrowserWindow({ width: 1000, height: 800, show: false, title: 'X · Tibo 发帖与回复', webPreferences: { partition, sandbox: true, contextIsolation: true, nodeIntegration: false } });
    win.setMenu(null);
    win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    for (const event of ['will-navigate', 'will-redirect']) win.webContents.on(event, (e, url) => { if (!allowed(url)) e.preventDefault(); });
    win.on('close', e => { if (!this.quitting) { e.preventDefault(); win.hide(); } });
    return win;
  }
  show() { const w = this.window(); if (!w.webContents.getURL()) w.loadURL(URL_SOURCE).catch(() => {}); w.show(); }
  stop() { this.quitting = true; if (this.win && !this.win.isDestroyed()) this.win.destroy(); }
  async fetch() {
    const w = this.window();
    if (this.busy || w.isVisible()) throw new Error('请完成 X 登录后关闭 X 窗口，下一轮会继续读取');
    this.busy = true;
    try {
      await Promise.race([w.loadURL(URL_SOURCE), new Promise((_, reject) => { const t = setTimeout(() => reject(new Error('X 页面加载超时')), 25000); t.unref(); })]);
      const posts = new Map();
      for (let i = 0; i < 9; i++) {
        if (w.isVisible()) throw new Error('X 页面正在使用，请关闭后等待下一轮');
        await new Promise(r => setTimeout(r, 1000));
        const page = await w.webContents.executeJavaScript(`(() => ({ url: location.href, posts: [...document.querySelectorAll('article')].map(a => { const time = a.querySelector('time'); const link = time?.closest('a'); return { url: link?.href, date: time?.dateTime, text: a.querySelector('[data-testid="tweetText"]')?.innerText }; }) }))()`);
        if (!/^https:\/\/(www\.)?(x|twitter)\.com\/thsottiaux(\/with_replies)?\/?$/.test(page.url)) throw new Error('X 要求登录或当前页面不正确，请在设置中打开 X');
        for (const p of page.posts.slice(0,200)) if (/^https:\/\/x\.com\/thsottiaux\/status\/\d+$/.test(p.url) && p.text && p.text.length <= 30000 && Date.parse(p.date) <= Date.now() && Date.parse(p.date) >= Date.now()-7*86400000) posts.set(p.url,p);
        await w.webContents.executeJavaScript('window.scrollBy(0, 700)');
      }
      if (!posts.size) throw new Error('X 没有返回可核验动态，请检查登录；这不代表没有预告');
      const esc = s => String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
      return '<section class="desktop-tibo-radar" data-tibo-posts-updated-at="'+new Date().toISOString()+'">'+[...posts.values()].map(p=>'<li class="reset-tibo-post" data-tibo-post-id="'+p.url.split('/').at(-1)+'" data-reset-relevance="unknown"><a href="'+esc(p.url)+'">Tibo</a><time datetime="'+esc(p.date)+'"></time><p class="reset-tibo-post-original">'+esc(p.text)+'</p></li>').join('')+'</section>';
    } finally { this.busy = false; }
  }
}
module.exports = { XSource };
