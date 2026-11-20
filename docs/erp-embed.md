# ERP embed bridge (iframe)

The ERP shell (`erp.tripwave.cloud`, `dev-erp.tripwave.cloud`) embeds this Chatwoot
in an iframe. Because the two hosts are different origins, the ERP cannot touch this
document: no `contentDocument`, no class toggle, no reading the sidebar. This bridge
is the contract that makes the embedding feel native.

It is **entirely optional and env-gated**: without `ERP_EMBED_ALLOWED_ORIGINS` the
layout does not even render the partial, and Chatwoot behaves exactly like stock.

## What it does

| Feature | How |
|---|---|
| Theme follows the ERP | ERP sends `erp:theme`; the bridge sets `dark` on `<html>` + `<body>` and sets `color-scheme`. `window.__ERP_THEME_LOCK__` makes `themeHelper.js` / `v3/App.vue` ignore `prefers-color-scheme` while embedded. |
| Chatwoot's sidebar is hidden | `html.erp-embed aside { display: none }`, injected when embedded. Navigation moves to the ERP shell. |
| ERP renders the real menu | The bridge scrapes the rendered `aside a[href]` (label, path, icon SVG) and posts it as `chatwoot:menu`. No Vue internals → survives upstream upgrades. |
| ERP drives navigation | `erp:navigate` clicks the matching router-link (client-side push), falling back to `location.assign`. |
| ERP highlights the current item | `history.pushState`/`replaceState`/`popstate` are wrapped to post `chatwoot:route`. |

## Env

| Env | Effect |
|---|---|
| `ERP_EMBED_ALLOWED_ORIGINS` | Comma-separated origins allowed to drive the bridge, e.g. `https://erp.tripwave.cloud,https://dev-erp.tripwave.cloud`. Unset → bridge disabled. |

## Message contract

```text
ERP → Chatwoot
  { type: 'erp:theme',        dark: boolean }
  { type: 'erp:navigate',     path: string }     // pathname + search, e.g. /app/accounts/1/dashboard
  { type: 'erp:menu:refresh' }

Chatwoot → ERP
  { type: 'chatwoot:ready',   path: string }
  { type: 'chatwoot:menu',    items: [{ label, path, external, icon }] }
  { type: 'chatwoot:route',   path: string }
```

Both sides must verify `event.origin`: the bridge drops anything outside
`ERP_EMBED_ALLOWED_ORIGINS` and requires `event.source === window.parent`.

## How the iframe enters embed mode

1. The ERP appends `erp_embed=1&erp_theme=dark|light` to the ticket URL
   (`/erp/sso?ticket=…`).
2. `Custom::ErpSsoController` forwards the sanitised pair to `/app/login`.
3. The bridge stores both in `localStorage`, so SPA navigations and reloads keep the
   embed mode without re-sending the params.
4. `erp_embed=0` explicitly clears that storage — the ERP uses it for the
   "open in a new tab" path, which must show the standalone app (own sidebar,
   own theme handling).

Outside the iframe the flag is never set, so a direct visit to
`https://chat.tripwave.cloud` is unchanged (this is the emergency standalone mode).

## Files

| Path | Role |
|---|---|
| `app/views/layouts/vueapp.html.erb` | adds `erpEmbedAllowedOrigins` to `window.chatwootConfig`, renders the partial |
| `custom/app/views/custom/_erp_embed.html.erb` | the bridge (inline ES5, no build step) |
| `custom/config/initializers/erp_embed.rb` | registers `custom/app/views` (only when enabled) |
| `app/javascript/dashboard/helper/themeHelper.js` | honours the theme lock |
| `app/javascript/v3/App.vue` | honours the theme lock (login page) |
| `custom/app/controllers/custom/erp_sso_controller.rb` | forwards `erp_embed` / `erp_theme` |

## Upgrade notes

The bridge depends on two stable Chatwoot facts: the layout file name (`vueapp`) and
the agent sidebar being an `<aside>` containing `<a href>` links. Neither is part of
the public API, so after an upstream sync:

1. `grep -n "erpEmbedAllowedOrigins" app/views/layouts/vueapp.html.erb` — the config
   key must still be injected;
2. open the dashboard, check the console for `chatwoot:menu` (or verify the ERP menu
   is populated);
3. if the sidebar was renamed, adjust the `querySelector('aside')` selector in the
   partial only — the ERP side needs no change.
