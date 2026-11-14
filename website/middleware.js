import { next } from "@vercel/functions";
import { localeRedirectPath } from "./locale-match.js";

export const config = {
  matcher: "/",
};

export default function middleware(request) {
  const path = localeRedirectPath(request);
  if (!path) return next();
  const url = new URL(request.url);
  url.pathname = path;
  return new Response(null, {
    status: 307,
    headers: {
      Location: `${url.pathname}${url.search}`,
      Vary: "Accept-Language, Cookie",
      "Cache-Control": "private, no-store",
    },
  });
}
