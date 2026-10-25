// Install before the real controls load: this canvas has no network transport or bridge credentials.
(() => {
  window.fetch = async (input, options = {}) => {
    const url = new URL(typeof input === "string" ? input : input.url, location.href);
    if (url.origin !== location.origin || !url.pathname.startsWith("/api/")) throw new TypeError("Preview transport accepts only local demo actions");
    if (url.pathname.includes("/snapshot")) return new Response('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360"><rect width="640" height="360" fill="#a7c7cf"/><path d="M0 245 140 150l180 95 140-130 180 130v115H0" fill="#699a86"/><path d="m240 215 80-70 80 70v110H240Z" fill="#f4eee3"/><path d="m225 218 95-87 95 87" fill="none" stroke="#596574" stroke-width="14"/><rect x="298" y="258" width="44" height="67" rx="4" fill="#cf986d"/></svg>', { headers: { "Content-Type": "image/svg+xml" } });
    if (url.pathname.includes("/live")) return new Response("", { status: 404 });
    const body = options.body ? JSON.parse(options.body) : {};
    if (window.designDemoState === "unavailable") {
      parent.postMessage({ type: "design-action", error: "No Response", body }, location.origin);
      return new Response(JSON.stringify({ error: "No Response" }), { status: 503, headers: { "Content-Type": "application/json" } });
    }
    window.designApplyWrite?.(body);
    return new Response("{}", { headers: { "Content-Type": "application/json" } });
  };
})();
