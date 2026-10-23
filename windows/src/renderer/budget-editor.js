(function (root) {
  const commonJS = typeof module === "object" && module.exports;
  const input = commonJS ? require("../core/budget-input") : root.ProjectBudgetInput;
  const labels = commonJS ? require("../core/display-labels") : root.DisplayLabels;
  const errors = commonJS ? require("./error-message") : root.ErrorMessages;

  function mount({ document, api, notify }) {
    const project = document.querySelector("#budgetProject");
    const limit = document.querySelector("#budgetLimit");
    const save = document.querySelector("#saveBudget");
    const remove = document.querySelector("#removeBudget");
    const feedback = document.querySelector("#budgetFeedback");
    const drafts = new Map();
    let budgets = [], projects = [], signature = "", pending = false, lastState = null;

    function setFeedback(message = "", kind = "") {
      feedback.textContent = message;
      feedback.dataset.kind = kind;
      limit.setAttribute("aria-invalid", String(kind === "error"));
    }
    function controls() {
      let valid = false;
      try { input.parse(limit.value); valid = true; } catch {}
      project.disabled = pending || !projects.length;
      limit.disabled = pending || !project.value;
      save.disabled = pending || !project.value || !valid;
      remove.disabled = pending || !budgets.some((row) => row.id === project.value);
      save.textContent = pending ? "处理中…" : "保存";
    }
    function loadSelection() {
      const saved = budgets.find((row) => row.id === project.value);
      limit.value = drafts.get(project.value) ??
        (saved ? saved.monthlyTokenLimit.toLocaleString("en-US") : "");
      setFeedback(project.value ? "" : "暂无已识别项目，读取到项目用量后可设置预算");
      controls();
    }
    function sync(next) {
      lastState = next;
      budgets = next.budgets || [];
      const draftProjects = projects.filter(row => drafts.has(row.id));
      projects = [...new Map([
        ...draftProjects, ...(next.tokenStats?.monthTopProjects || []), ...budgets,
      ].map((row) => [row.id, row])).values()];
      const previous = project.value;
      const nextSignature = JSON.stringify(projects.map((row) =>
        [row.id, row.projectName, row.projectPath]));
      if (!pending && signature !== nextSignature) {
        signature = nextSignature;
        project.replaceChildren(...projects.map((row) => {
          const option = document.createElement("option");
          option.value = row.id;
          option.textContent = labels.projectName(row.projectName, row.projectPath);
          return option;
        }));
        if (projects.some((row) => row.id === previous)) project.value = previous;
      }
      // Background status updates must not overwrite a draft or hide its error.
      if (!pending && (previous !== project.value || !drafts.has(project.value)))
        loadSelection();
      controls();
    }
    async function submit(removing = false) {
      if (pending) return;
      const id = project.value;
      let value;
      try {
        if (!id) throw new Error("请选择已识别项目");
        if (removing) {
          if (!budgets.some((row) => row.id === id)) return;
          value = { id, remove: true };
        } else {
          value = { id, limit: input.parse(limit.value) };
          if (!budgets.some(row => row.id === id) && !(lastState?.tokenStats?.monthTopProjects || []).some(row => row.id === id)) {
            const projectDraft = projects.find(row => row.id === id);
            if (projectDraft) value.projectDraft = { id, projectName: projectDraft.projectName, projectPath: projectDraft.projectPath };
          }
        }
      } catch (error) {
        drafts.set(id, limit.value);
        setFeedback(errors.readable(error), "error");
        limit.focus();
        return;
      }
      drafts.set(id, limit.value);
      pending = true;
      setFeedback();
      controls();
      try {
        const result = await api.setBudget(value);
        if (result?.ok === false) throw new Error(result.error || "预算保存失败，请重试");
        if (Array.isArray(result)) budgets = result;
        drafts.delete(id);
        limit.value = removing ? "" : value.limit.toLocaleString("en-US");
        const message = removing ? "预算已删除" : "预算已保存";
        setFeedback(message, "success");
        notify(message, "success");
      } catch (error) {
        const message = errors.readable(error, "预算保存失败，请重试");
        setFeedback(message, "error");
        notify(message, "error");
      } finally {
        pending = false;
        controls();
      }
    }
    project.addEventListener("change", loadSelection);
    limit.addEventListener("input", () => {
      drafts.set(project.value, limit.value);
      try { input.parse(limit.value); setFeedback(); }
      catch (error) { setFeedback(errors.readable(error), "error"); }
      controls();
    });
    limit.addEventListener("keydown", (event) => {
      if (event.key === "Enter") { event.preventDefault(); void submit(); }
    });
    save.addEventListener("click", () => submit());
    remove.addEventListener("click", () => submit(true));
    controls();
    return { sync };
  }
  if (commonJS) module.exports = { mount };
  else root.PulseBudgetEditor = { mount };
})(typeof globalThis !== "undefined" ? globalThis : this);
