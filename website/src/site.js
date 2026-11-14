(() => {
  const root = document.querySelector("[data-showcase]");
  if (!root) return;
  const tabs = [...root.querySelectorAll("[data-tab]")];
  const panels = tabs.map((tab) => document.getElementById(tab.getAttribute("aria-controls")));
  if (tabs.length === 0 || panels.some((panel) => !panel)) return;

  function select(tab) {
    for (const item of tabs) {
      const selected = item === tab;
      item.setAttribute("aria-selected", String(selected));
      item.tabIndex = selected ? 0 : -1;
      const panel = document.getElementById(item.getAttribute("aria-controls"));
      panel.hidden = !selected;
    }
  }

  root.classList.add("is-ready");
  select(tabs.find((tab) => tab.getAttribute("aria-selected") === "true") || tabs[0]);

  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => select(tab));
    tab.addEventListener("keydown", (event) => {
      let next;
      if (event.key === "ArrowRight") next = tabs[(index + 1) % tabs.length];
      if (event.key === "ArrowLeft") next = tabs[(index - 1 + tabs.length) % tabs.length];
      if (event.key === "Home") next = tabs[0];
      if (event.key === "End") next = tabs[tabs.length - 1];
      if (!next) return;
      event.preventDefault();
      select(next);
      next.focus();
    });
  });
})();
