(function(root) {
  function mount({ document, api, notify }) {
    const form = document.querySelector('#batchForm'), list = document.querySelector('#expiryBatches');
    const feedback = document.createElement('p'); feedback.className = 'record-feedback'; feedback.setAttribute('role', 'status'); form.after(feedback);
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.textContent = '新增批次'; form.append(cancel);
    let rows = [], scope = null, draftScope = null, editing = null, pending = false, dirty = false, signature = '';
    const field = name => form.elements.namedItem(name);
    const submit = form.querySelector('[type="submit"]');
    function controls() { for (const el of form.elements) el.disabled = pending; submit.textContent = pending ? '正在保存…' : editing ? '保存修改' : '添加批次'; }
    function selection(row) {
      editing = row?.id || null; draftScope = scope; dirty = false;
      for (const name of ['credits', 'grantedOn', 'expiresOn', 'kind', 'evidence']) field(name).value = row ? String(row[name]) : name === 'kind' ? 'confirmed' : '';
      feedback.textContent = ''; controls();
    }
    form.addEventListener('input', () => { dirty = true; if (!draftScope) draftScope = scope; });
    cancel.onclick = () => { if (!pending) selection(null); };
    form.addEventListener('submit', async e => {
      e.preventDefault(); if (pending) return;
      const submittedScope = draftScope || scope;
      if (submittedScope !== scope) { feedback.textContent = '账户已切换；草稿保留，请复制后点击新增批次并核对当前账户'; return; }
      let value;
      try { value = { ...Object.fromEntries(new FormData(form)), id: editing || undefined, recreate: !!editing && !rows.some(r => r.id === editing), accountScope: submittedScope }; value.credits = CreditAmount.parse(value.credits); }
      catch (error) { feedback.textContent = error.message; return; }
      const old = new Set(rows.map(r => r.id)); pending = true; controls();
      try {
        const saved = await api.setExpiryBatch(value);
        if (scope !== submittedScope) { feedback.textContent = '提交属于原账户；当前草稿保留，请核对账户'; return; }
        rows = saved;
        const row = saved.find(r => editing ? r.id === editing : !old.has(r.id));
        if (row) selection(row);
        feedback.textContent = '批次已保存，可继续编辑'; notify('批次已保存');
      } catch (error) { feedback.textContent = ErrorMessages.readable(error, '保存失败，输入已保留'); }
      finally { pending = false; controls(); }
    });
    function sync(next) {
      const previousScope = scope;
      scope = next.accountScope || null;
      rows = next.creditExpiryBatches || [];
      if (previousScope && previousScope !== scope && (dirty || editing || pending)) feedback.textContent = '账户已切换，原账户草稿已保留，请核对后重新提交';
      const sig = JSON.stringify(rows) + scope;
      if (sig === signature) return; signature = sig; list.replaceChildren();
      for (const row of rows) {
        const item = document.createElement('div'); item.className = 'batch-row';
        const copy = document.createElement('span'); copy.textContent = `${row.credits} credits · ${row.grantedOn} 发放 · ${row.expiresOn} 到期 · ${row.kind === 'confirmed' ? '已核实' : '个人推算'}\n${row.evidence}`;
        const edit = document.createElement('button'); edit.type = 'button'; edit.textContent = '编辑'; edit.onclick = () => { if (!pending) selection(row); };
        const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = '删除';
        remove.onclick = async () => {
          if (pending) return; pending = true; controls();
          try { await api.setExpiryBatch({ id: row.id, accountScope: scope, remove: true }); if (editing === row.id) selection(null); }
          catch (error) { feedback.textContent = ErrorMessages.readable(error, '删除失败'); }
          finally { pending = false; controls(); }
        };
        item.append(copy, edit, remove); list.append(item);
      }
      if (!rows.length) list.textContent = '当前账户暂无批次记录';
      controls();
    }
    return { sync };
  }
  root.PulseExpiryEditor = { mount };
})(globalThis);
