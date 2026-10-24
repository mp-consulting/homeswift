# Translations

The web UI, plugins' pages and the Assistant speak English, French, Spanish (Spain) and Portuguese (Portugal).
Each user picks a language under Settings → Appearance → Language, or keeps Automatic, which follows the browser.
The choice is saved with the user's other preferences (`language` in `ui-preferences.json`: `auto`, `en`, `fr`,
`es` or `pt`), so it follows them from one browser to the next. Logs, the command line and the MCP server's tool
texts stay in English.

## How it works

`Sources/HomeswiftUI/Web/i18n.js` is the first script of every page (the server adds it to plugins' pages). It
picks the language, sets `<html lang>`, and loads the language's catalog before any other script:
`i18n-fr.js`, `i18n-es.js` or `i18n-pt.js`. The English text is the key:

```js
const { t, tn } = HomeswiftI18n;

el("button", { text: t("Restart") });
t("Restart {name}", { name: bridge.name });         // placeholders in braces; numbers are formatted for the locale
tn("{n} accessory", "{n} accessories", count);      // the language's plural rules pick the form; {n} is the count
HomeswiftI18n.message(error.message);               // text from the server: translated when a catalog knows it
new Intl.DateTimeFormat(HomeswiftI18n.locale, {…})  // dates and numbers in the page's locale (fr-FR, es-ES, pt-PT)
```

A string a catalog lacks stays in English. A catalog is one call around one JSON object:

```js
HomeswiftI18n.add("fr", {
  "Restart": "Redémarrer",
  "Restart {name}": "Redémarrer {name}",
  "{n} accessory": "{n} accessoire",
  "{n} accessories": "{n} accessoires"
});
```

Static HTML takes a `data-i18n` attribute: the element's own text and its `title`, `aria-label`, `placeholder`
and `alt` are translated when the page loads.

```html
<label data-i18n>Username <input name="username"></label>
<button data-i18n aria-label="Account menu">…</button>
```

Errors from the server are English sentences. The pages pass them through `HomeswiftI18n.message`, which looks
them up as written, then as catalog keys whose `{0}`, `{1}` stand for the variable parts
(`"the message is too long: {0} characters at most"`). The API helpers (`api()` in common.js and app.js, and
`homeswift.request()` on plugins' pages) do it for every refusal.

The pages send their locale as `Accept-Language`; the Assistant's requests from the UI (chat, explain, ask, Log
Doctor, the digest, room suggestions, the config copilot) answer in that language (`Prompts.answerLanguage`,
`AssistantService.speaking`).

## Writing strings

- Wrap every text a person reads: `text:`, `textContent`, `title`, `aria-label`, `placeholder`, `alt`,
  `confirm()` and `alert()`, toasts, and errors the page writes itself. Not CSS classes, ids, API values,
  config keys, log lines, names from devices or the user, or `console` messages.
- The key is a plain double-quoted literal written in the call: `t("Save")`, never `t(variable)` or a template
  literal. `UITests.webStringsAreTranslated` reads them from the source and fails when a catalog lacks one or a
  translation drops a placeholder.
- A sentence is one key, with placeholders for what changes: `t("Delete {name}?", { name })`, not
  `t("Delete") + " " + name + "?"`. Languages put words in another order.
- Counts go through `tn`, with both English forms.
- A word English uses in two senses takes a context in brackets, which English never shows: `t("On")` is a light
  that is on (*Allumé*), `t("On [setting]")` a setting that is on (*Activé*).
- Code never compares displayed text: keep the state in a variable.

## Plugins' pages

A plugin's page gets `HomeswiftI18n` from the server like the UI's own pages. Its strings go in its own
`Web/i18n.js`, loaded before its `app.js`, with the three languages in one call:

```js
HomeswiftI18n.add({
  fr: { "Your lights": "Vos lampes" },
  es: { "Your lights": "Tus luces" },
  pt: { "Your lights": "As suas luzes" }
});
```

```html
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="app.js"></script>
```

Errors a plugin's `handleWebRequest` answers go in the same file, as for the server's.

## Style

Translations follow the English's tone: short, plain and concrete, in sentence case. Product names, config keys
and code stay as they are: Homeswift, HomeKit, Homebridge, Apple, Glass UI, config.json, HomeswiftAiKit,
HomeswiftUI, JSON, MCP, OAuth, plugins' and brands' names, units.

- French: *vous*. A no-break space (U+00A0) before `:` and inside « », a narrow no-break space (U+202F) before
  `;`, `!` and `?`.
- Spanish (Spain): *tú*, as Apple's Spanish does. Opening `¿` and `¡`.
- Portuguese (Portugal), with the 1990 spelling: no *tu* or *você*; imperatives and impersonal phrasing
  (*Introduza o código*, *Escolha um plugin*). Portugal's words: *ecrã*, *utilizador*, *ficheiro*,
  *palavra-passe*, *registo*, *ligação*, *definições*.

| English | French | Spanish | Portuguese |
|---|---|---|---|
| bridge | pont | puente | ponte (f.) |
| child bridge | pont enfant | puente secundario | ponte secundária |
| accessory | accessoire | accesorio | acessório |
| plugin | plugin | plugin | plugin |
| platform (config block) | plateforme | plataforma | plataforma |
| scene | scène | escena | cena |
| room | pièce | habitación | divisão |
| the Home app | l'app Maison | la app Casa | a app Casa |
| Status | État | Estado | Estado |
| Accessories | Accessoires | Accesorios | Acessórios |
| Scenes | Scènes | Escenas | Cenas |
| Config | Config | Configuración | Configuração |
| Logs | Journaux | Registros | Registos |
| Settings | Réglages | Ajustes | Definições |
| Appearance | Apparence | Apariencia | Aspeto |
| the Assistant | l'Assistant | el Asistente | o Assistente |
| sign in / sign out | se connecter / se déconnecter | iniciar sesión / cerrar sesión | iniciar sessão / terminar sessão |
| account | compte | cuenta | conta |
| username | nom d'utilisateur | nombre de usuario | nome de utilizador |
| password | mot de passe | contraseña | palavra-passe |
| set-up code | code de configuration | código de configuración | código de configuração |
| pair, pairing | jumeler, jumelage | emparejar, emparejamiento | emparelhar, emparelhamento |
| two-factor authentication | authentification à deux facteurs | autenticación de dos factores | autenticação de dois fatores |
| API token | jeton d'API | token de API | token de API |
| restart | redémarrer | reiniciar | reiniciar |
| backup, restore | sauvegarde, restaurer | copia de seguridad, restaurar | cópia de segurança, restaurar |
| update (software) | mise à jour | actualización | atualização |
| paused | en pause | en pausa | em pausa |
| wallpaper | fond d'écran | fondo de pantalla | papel de parede |
| widget | widget | widget | widget |
| notification | notification | notificación | notificação |
| usage, budget (tokens) | utilisation, budget | uso, presupuesto | utilização, orçamento |
| token (a model's, in usage and budgets) | token | token | token |
| connected apps | apps connectées | apps conectadas | apps ligadas |
| expert view | vue expert | vista experta | vista avançada |
| camera, doorbell | caméra, sonnette | cámara, timbre | câmara, campainha |
| light, lightbulb | lampe, ampoule | luz, bombilla | luz, lâmpada |
| switch, outlet | interrupteur, prise | interruptor, enchufe | interruptor, tomada |
| thermostat | thermostat | termostato | termóstato |
| sensor | capteur | sensor | sensor |
| lock | serrure | cerradura | fechadura |
| garage door | porte de garage | puerta de garaje | porta de garagem |
| window covering, blinds | store | persiana | estore |
| fan | ventilateur | ventilador | ventoinha |
| air purifier | purificateur d'air | purificador de aire | purificador de ar |
| security system | système de sécurité | sistema de seguridad | sistema de segurança |
| television | téléviseur | televisor | televisor |
| brightness | luminosité | brillo | brilho |
| hue, saturation | teinte, saturation | tono, saturación | matiz, saturação |
| colour temperature | température de couleur | temperatura de color | temperatura de cor |
| Adaptive Lighting | Éclairage adaptatif | Iluminación adaptativa | Iluminação adaptativa |
| on, off (a device) | allumé, éteint | encendido, apagado | ligado, desligado |
| on, off (a setting) | activé, désactivé | activado, desactivado | ativado, desativado |
