export const COOKIE = "screenclip_lang";

export const LOCALES = ["en", "zh-hans", "es", "ja", "pt-br", "de", "fr", "ko", "ru", "zh-hant"];

const EXACT = {
  en: "en",
  "zh-hans": "zh-hans",
  "zh-cn": "zh-hans",
  "zh-sg": "zh-hans",
  zh: "zh-hans",
  "zh-hant": "zh-hant",
  "zh-tw": "zh-hant",
  "zh-hk": "zh-hant",
  "zh-mo": "zh-hant",
  es: "es",
  ja: "ja",
  "pt-br": "pt-br",
  pt: "pt-br",
  "pt-pt": "pt-br",
  de: "de",
  fr: "fr",
  ko: "ko",
  ru: "ru",
};

const BOT = /bot|crawler|spider|slurp|facebookexternalhit|embedly|quora|whatsapp|telegram|slackbot|discord|linkedinbot|pinterest|applebot|baiduspider|yandex|duckduckbot|semrush|ahrefs|lighthouse|chrome-lighthouse/i;

export function lookupTag(tag) {
  const norm = String(tag || "").trim().toLowerCase().replace(/_/g, "-");
  if (!norm || norm === "*") return null;
  const parts = norm.split("-").filter(Boolean);
  const candidates = [norm];
  if (parts.length >= 2) candidates.push(`${parts[0]}-${parts[1]}`);
  if (parts[0]) candidates.push(parts[0]);
  for (const candidate of candidates) {
    if (EXACT[candidate]) return EXACT[candidate];
  }
  return null;
}

export function parseAcceptLanguage(header) {
  if (!header) return [];
  const items = [];
  for (const part of String(header).split(",")) {
    const [range, ...params] = part.trim().split(";");
    if (!range) continue;
    let q = 1;
    for (const param of params) {
      const [key, value] = param.trim().split("=");
      if (key === "q") q = Number(value);
    }
    if (!Number.isFinite(q) || q <= 0) continue;
    items.push({ range: range.trim(), q, index: items.length });
  }
  items.sort((a, b) => b.q - a.q || a.index - b.index);
  return items.map((item) => item.range);
}

export function matchTags(tags) {
  for (const tag of tags || []) {
    const hit = lookupTag(tag);
    if (hit) return hit;
  }
  return "en";
}

export function matchAcceptLanguage(header) {
  return matchTags(parseAcceptLanguage(header));
}

export function isCrawler(userAgent) {
  return BOT.test(userAgent || "");
}

export function readCookie(header, name = COOKIE) {
  if (!header) return "";
  for (const part of String(header).split(";")) {
    const separator = part.indexOf("=");
    if (separator === -1) continue;
    const key = part.slice(0, separator).trim();
    if (key !== name) continue;
    try {
      return decodeURIComponent(part.slice(separator + 1).trim());
    } catch {
      return "";
    }
  }
  return "";
}

export function localeRedirectPath(request) {
  const url = new URL(request.url);
  if (url.pathname !== "/") return null;
  if (request.method !== "GET" && request.method !== "HEAD") return null;
  const dest = request.headers.get("sec-fetch-dest");
  if (dest && dest !== "document") return null;
  const mode = request.headers.get("sec-fetch-mode");
  if (mode && mode !== "navigate") return null;
  if (isCrawler(request.headers.get("user-agent"))) return null;
  const saved = readCookie(request.headers.get("cookie"));
  let code;
  if (LOCALES.includes(saved)) code = saved;
  else code = matchAcceptLanguage(request.headers.get("accept-language"));
  if (!code || code === "en") return null;
  return `/${code}`;
}
