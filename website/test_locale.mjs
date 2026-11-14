import assert from "node:assert/strict";
import { matchAcceptLanguage, localeRedirectPath, isCrawler } from "./locale-match.js";

assert.equal(matchAcceptLanguage("ja,en-US;q=0.8,en;q=0.7"), "ja");
assert.equal(matchAcceptLanguage("en-US,en;q=0.9"), "en");
assert.equal(matchAcceptLanguage("zh-TW,zh;q=0.8,en;q=0.5"), "zh-hant");
assert.equal(matchAcceptLanguage("zh-Hant-HK"), "zh-hant");
assert.equal(matchAcceptLanguage("zh-CN,zh-Hans;q=0.9"), "zh-hans");
assert.equal(matchAcceptLanguage("zh"), "zh-hans");
assert.equal(matchAcceptLanguage("pt-BR,pt;q=0.9,en;q=0.8"), "pt-br");
assert.equal(matchAcceptLanguage("pt-PT"), "pt-br");
assert.equal(matchAcceptLanguage("fr-CA,fr;q=0.8"), "fr");
assert.equal(matchAcceptLanguage("de-AT"), "de");
assert.equal(matchAcceptLanguage("ko-KR,ko;q=0.9"), "ko");
assert.equal(matchAcceptLanguage("ru;q=0.2,de;q=0.9,en;q=0.4"), "de");
assert.equal(matchAcceptLanguage("es-MX,es;q=0.8"), "es");
assert.equal(matchAcceptLanguage("*"), "en");
assert.equal(matchAcceptLanguage(""), "en");

function request(headers, path = "/") {
  return new Request(`https://screenclipai.com${path}`, { headers });
}

const browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15";
assert.equal(localeRedirectPath(request({ "accept-language": "ja", "user-agent": browser })), "/ja");
assert.equal(localeRedirectPath(request({ "accept-language": "en-US", "user-agent": browser })), null);
assert.equal(
  localeRedirectPath(request({ "accept-language": "ja", "user-agent": browser, cookie: "screenclip_lang=en" })),
  null
);
assert.equal(
  localeRedirectPath(request({ "accept-language": "en", "user-agent": browser, cookie: "screenclip_lang=ru" })),
  "/ru"
);
assert.equal(
  localeRedirectPath(request({ "accept-language": "ja", "user-agent": "Mozilla/5.0 (compatible; Googlebot/2.1)" })),
  null
);
assert.equal(localeRedirectPath(request({ "accept-language": "ja", "user-agent": browser }, "/ja")), null);
assert.equal(isCrawler("Mozilla/5.0 Chrome-Lighthouse"), true);
assert.equal(isCrawler(browser), false);
console.log("locale matching ok");
