// The explorer and its isolated canvas use the same language and appearance as the selected story.
(() => {
  const query = new URLSearchParams(location.search);
  const language = query.get("lang") || localStorage.getItem("homeswift.design.language") || "en";
  const chosen = ["en", "fr", "es", "pt"].includes(language) ? language : "en";
  let preferences = {};
  try { preferences = JSON.parse(localStorage.getItem("homeswift.preferences") || "{}"); } catch {}
  localStorage.setItem("homeswift.preferences", JSON.stringify({ ...preferences, language: chosen }));
  const theme = query.get("theme") || localStorage.getItem("homeswift.design.theme") || "light";
  document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light";
})();
