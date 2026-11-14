import { COOKIE, LOCALES, isCrawler, matchTags, readCookie } from "/assets/locale-match.js";

function savedChoice() {
  const cookie = readCookie(document.cookie);
  if (LOCALES.includes(cookie)) return cookie;
  try {
    const stored = localStorage.getItem(COOKIE);
    if (LOCALES.includes(stored)) return stored;
  } catch {
    /* Storage can be blocked. The cookie still works when it is present. */
  }
  return "";
}

function remember(code) {
  try {
    localStorage.setItem(COOKIE, code);
  } catch {
    /* Ignore private-mode storage failures. */
  }
  const secure = location.protocol === "https:" ? "; Secure" : "";
  document.cookie = `${COOKIE}=${encodeURIComponent(code)}; Path=/; Max-Age=31536000; SameSite=Lax${secure}`;
}

function maybeRedirect() {
  if (location.pathname !== "/") return;
  if (isCrawler(navigator.userAgent)) return;
  const saved = savedChoice();
  const code = saved || matchTags(navigator.languages || [navigator.language || "en"]);
  if (!code || code === "en") return;
  location.replace(`/${code}${location.search}${location.hash}`);
}

for (const link of document.querySelectorAll("[data-lang-switcher] a[data-locale]")) {
  link.addEventListener("click", () => {
    const code = link.getAttribute("data-locale");
    if (LOCALES.includes(code)) remember(code);
  });
}

maybeRedirect();
