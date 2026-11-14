(() => {
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  const caption = document.querySelector('#screenshot-caption');
  const captions = {
    'tab-capture': 'A quick note. An arrow if you need one. All the context in one capture.',
    'tab-queue': 'See what’s working, answer a question, and come back when the fix is ready to retest.'
  };

  function selectTab(tab) {
    for (const item of tabs) {
      const selected = item === tab;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
      document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
    }
    caption.textContent = captions[tab.id];
  }

  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => selectTab(tab));
    tab.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length];
      if (event.key === 'ArrowLeft') next = tabs[(index - 1 + tabs.length) % tabs.length];
      if (event.key === 'Home') next = tabs[0];
      if (event.key === 'End') next = tabs[tabs.length - 1];
      if (!next) return;
      event.preventDefault();
      selectTab(next);
      next.focus();
    });
  });
})();
