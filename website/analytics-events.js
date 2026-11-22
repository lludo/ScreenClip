/*
 * ScreenClip site: first-party Vercel Web Analytics custom events (no visible UI).
 * Standard Pro Web Analytics only: at most 2 properties per event, no personal data.
 *
 *   app_store_click  { app, placement }
 *     Fires on the Mac disk-image download (GitHub Releases). The app is not
 *     distributed through Apple's store. The event name matches the other
 *     project sites so weekly reporting can use one conversion event.
 */
(function () {
  'use strict';

  window.va = window.va || function () { (window.vaq = window.vaq || []).push(arguments); };

  function track(name, data) {
    try {
      if (typeof window.va === 'function') {
        window.va('event', { name: name, data: data });
      }
    } catch (e) {
      /* never block navigation */
    }
  }

  function isDiskImage(href) {
    var url = href || '';
    if (/\.dmg(\?|#|$)/i.test(url)) return true;
    if (/github\.com\/lludo\/ScreenClip\/releases\/(latest\/)?download\//i.test(url)) return true;
    return false;
  }

  function placementFor(link) {
    if (link.closest('.site-header, header, .header-cta')) return 'header';
    if (link.closest('#download')) return 'download';
    var section = link.closest('section');
    var sectionClass = (section && section.className) || '';
    if (/hero|intro/.test(sectionClass)) return 'hero';
    if (link.closest('footer, .site-footer')) return 'footer';
    return 'other';
  }

  function onActivate(event) {
    if (event.type === 'auxclick' && event.button !== 1) return;
    var link = event.target && event.target.closest ? event.target.closest('a[href]') : null;
    if (!link) return;
    if (!isDiskImage(link.href || link.getAttribute('href') || '')) return;
    track('app_store_click', { app: 'ScreenClip', placement: placementFor(link) });
  }

  document.addEventListener('click', onActivate, true);
  document.addEventListener('auxclick', onActivate, true);
})();
