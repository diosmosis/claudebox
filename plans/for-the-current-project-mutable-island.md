# AS-606 — Lock the WooCommerce Matomo plugin's update (and optionally tracking) URL to a trusted Matomo instance

## Context

The embedded WordPress plugin (`woocommerce-piwik-analytics`) decides where to check for
and download plugin updates from the value stored in the WooCommerce option
`woopiwik_piwik_url`. That URL is fed to the Plugin Update Checker
(`Puc_v4_Factory::buildUpdateChecker`) in `WooPiwik::updateCheck()`. The update checker
periodically fetches a metadata JSON from that URL and then **downloads and installs the
plugin ZIP it points to**. If an attacker can change the `woopiwik_piwik_url` option, they
control where update code comes from → remote code execution.

Fix: stop deriving the *update* URL from a mutable option. Instead bake a hardcoded URL into
the plugin at download time via a `config.php` file that defines a PHP constant. The Matomo
server generates that `config.php` dynamically when an admin downloads the plugin, choosing
the target host from Matomo's configured `trusted_hosts`. Per the ticket owner, the same
hardcoded instance URL is **also used for tracking by default** (togglable), so an admin can
still point tracking at a manually-entered URL if they turn the option off.

Key files reviewed:
- `matomo/plugins/WooCommerceAnalytics/woocommerce-piwik-analytics/woocommerce-piwik-analytics.php` — plugin bootstrap.
- `.../classes/WooPiwik.php` — `updateCheck()`, the RCE sink.
- `.../classes/WooPiwik/Admin/Settings.php` — settings fields, validation, migration pattern (`maybeEnableAdminTokenForExistingInstalls`).
- `.../classes/WooPiwik/Admin.php` — admin notices.
- `.../classes/WooPiwik/Tracking/Tracker.php` — reads `FIELD_PIWIK_URL` for tracking.
- `matomo/plugins/WooCommerceAnalytics/Controller.php` — `download()` (streams static zip), `pluginUpdate()` (metadata), `install()` (renders download page).
- `matomo/plugins/WooCommerceAnalytics/templates/download.twig` + `vue/src/Download.vue` — download page UI.
- `matomo/core/Url.php::getTrustedHosts()` and `matomo/core/SettingsPiwik.php::getPiwikUrl()` — trusted-host + base-URL helpers to reuse.

## Design decisions (confirmed with user)
- New install with neither the const nor a legacy setting → **disable the update checker AND show a WP admin notice** explaining updates are unavailable.
- Download page → **dropdown of `trusted_hosts` only when there is more than one**; otherwise just show the single resolved URL.
- Scope → lock the update URL, **and** add an option (default ON) to also use that instance URL for tracking; when OFF, the Matomo URL text field is used for tracking. The generated const is the full base URL (scheme + host + path), so the host must be one of Matomo's trusted hosts.

---

## Part A — WordPress plugin (`woocommerce-piwik-analytics`)

### A1. The `config.php` const (+ manual `wp-config.php` override)
- New constant `WOOPIWIK_MATOMO_URL` = full base Matomo URL (e.g. `https://matomo.example.com/`), defined by a `config.php` at the plugin root.
- In `woocommerce-piwik-analytics.php`, after the `ABSPATH` guard and before instantiating classes, include it if present:
  ```php
  if (file_exists(__DIR__ . '/config.php')) {
      require_once __DIR__ . '/config.php';
  }
  ```
- **Manual override:** an admin can define `WOOPIWIK_MATOMO_URL` themselves in `wp-config.php` (which loads before plugins). To make that authoritative, both `config.php` and any generated content must guard the definition: `if (!defined('WOOPIWIK_MATOMO_URL')) { define(...); }` — a `wp-config.php` value therefore wins over the bundled `config.php`. Surface this in the settings help text (A6): "Advanced: you can override the Matomo instance URL by defining the `WOOPIWIK_MATOMO_URL` constant in `wp-config.php`; this takes precedence over the URL baked in at download."
- Add `config.php` to the plugin's `.gitignore` and to `update_zip.sh`'s exclude list so a stray local copy is never committed or shipped in the base zip (it is injected only at download time).

### A2. URL-resolution helpers (in `Settings.php`)
Add **instance** helpers so every consumer resolves URLs the same way. Because `WOOPIWIK_MATOMO_URL` is a real PHP constant (cannot be un-defined between test cases), add a **tests-only override**: an *instance* property `$instanceUrlForTesting` set via an optional constructor argument (`__construct($registerEvents = true, $instanceUrlForTesting = null)`) used only by tests. Keeping it an instance property (not static) avoids global mutable state leaking between test cases. `matomoInstanceUrl()` returns the constant when defined, otherwise `$this->instanceUrlForTesting`, otherwise `null`. In production the override stays `null` and the constant is authoritative. (No WordPress filter is added.)
- `matomoInstanceUrl(): ?string` — returns `WOOPIWIK_MATOMO_URL` if defined and non-empty, else `$this->instanceUrlForTesting`, else `null`.
- `getUpdateBaseUrl(): ?string` — **update mechanism**: returns the instance URL if set; else, only if `LEGACY_UPDATE_URL_ALLOWED === 'yes'`, the `FIELD_PIWIK_URL` option; else `null` (updates disabled).
- `isBoundToInstanceForTracking(): bool` — instance URL is set AND `FIELD_USE_MATOMO_INSTANCE_URL !== 'no'`.
- `getTrackingUrl(): string` — returns instance URL when bound, else the `FIELD_PIWIK_URL` option.

Because these are instance methods, callers that don't already hold a `Settings` build a throwaway `new Settings(false)` (established pattern — the constructor is inert when `$registerEvents` is false). `validate_settings()` uses `$this` directly.

New constants/options:
- `FIELD_USE_MATOMO_INSTANCE_URL = 'woopiwik_use_matomo_instance_url'` (yes/no).
- `LEGACY_UPDATE_URL_ALLOWED = 'woopiwik_legacy_update_url_allowed'` (yes/no).
- `UPDATE_URL_MIGRATED = 'woopiwik_update_url_migrated'`.

### A3. One-time migration (mirror `maybeEnableAdminTokenForExistingInstalls`)
Add `Settings::maybeMigrateUpdateUrl()`, called from `WooPiwik::__construct()` alongside the existing migration. Runs once (gated by `UPDATE_URL_MIGRATED`):
- **Existing install** (non-empty `FIELD_PIWIK_URL` at first run): `LEGACY_UPDATE_URL_ALLOWED = 'yes'` and default `FIELD_USE_MATOMO_INSTANCE_URL = 'no'` (preserve their manually-configured tracking URL; don't silently repoint tracking on upgrade).
- **Fresh install** (no URL yet): `LEGACY_UPDATE_URL_ALLOWED = 'no'` and default `FIELD_USE_MATOMO_INSTANCE_URL = 'yes'` (bind to the instance baked into `config.php`).

### A4. `WooPiwik::updateCheck()`
Replace `get_option('woopiwik_piwik_url')` with `(new Settings(false))->getUpdateBaseUrl()`. If it returns `null`, do not register the update checker (return early). Keep the existing URL normalization + `Puc_v4_Factory::buildUpdateChecker` on the resolved base URL.

### A5. Tracking uses the resolved URL
In `Tracker::__construct()`, replace `get_option(Settings::FIELD_PIWIK_URL)` with `(new Settings(false))->getTrackingUrl()`. In `Settings::validate_settings()`, use `$this->getTrackingUrl()` for the URL check (idSite/token unchanged) so validation and the ping use the effective URL.

### A6. Settings UI (`Settings::get_settings()`)
- Add a checkbox `FIELD_USE_MATOMO_INSTANCE_URL` ("Track to the connected Matomo instance", default `yes`), shown **only when `matomoInstanceUrl()` is set**. Description: explains tracking + auto-updates go to the Matomo instance this plugin was downloaded from, and notes the advanced `wp-config.php` override from A1 (define `WOOPIWIK_MATOMO_URL` yourself if the baked-in URL is wrong).
- Matomo URL text field (`FIELD_PIWIK_URL`):
  - When bound to the instance → render disabled/hidden and show the instance URL read-only (server-side authority: `getTrackingUrl()` ignores the field value when bound regardless).
  - When the instance const is absent (legacy / no `config.php`) → render exactly as today.
- Add a small JS toggle (extend the already-enqueued `assets/js/diagnostics.js`) to enable/disable the URL field live when the checkbox changes. Purely cosmetic; server side is authoritative.

### A7. "Updates disabled" admin notice (`Admin.php`)
In `Admin::__construct()`'s `init` hook, when Woo is installed, user is admin, and `(new Settings(false))->getUpdateBaseUrl() === null`, add an `admin_notices` action `addUpdatesDisabledNotice()` explaining auto-updates are unavailable because the plugin wasn't downloaded from a Matomo instance (and how to fix: re-download from the Matomo install page).

---

## Part B — Matomo plugin (`WooCommerceAnalytics`)

### B1. Candidate-URL helper (in `Controller.php`)
Add `buildCandidateMatomoUrls(string $currentUrl, array $trustedHosts): array` — parse scheme + path from `$currentUrl` (from `SettingsPiwik::getPiwikUrl()`), build `scheme://<host><path>` for each trusted host, always include the current URL, dedup. If `$trustedHosts` is empty, return `[$currentUrl]`. Reuse `Url::getTrustedHosts()`.

### B2. `install()` — download page data
Pass the candidate URLs to the template:
```php
return $this->renderTemplate('download', [
    'matomoUrls' => $this->buildCandidateMatomoUrls(SettingsPiwik::getPiwikUrl(), Url::getTrustedHosts()),
]);
```

### B3. `download()` — inject `config.php` into the zip
- Read `matomoUrl` request var (`Common::getRequestVar`). **Validate** it against a freshly recomputed `buildCandidateMatomoUrls(...)` allow-list (`in_array($requested, $allowed, true)`); on mismatch fall back to `SettingsPiwik::getPiwikUrl()`. Never write an unvalidated param into `config.php`.
- Build config contents via `buildConfigFileContents(string $url)`. Guard the define so a `wp-config.php` override wins (A1):
  ```php
  "<?php\nif (!defined('ABSPATH')) { exit; }\nif (!defined('WOOPIWIK_MATOMO_URL')) { define('WOOPIWIK_MATOMO_URL', '" . addslashes($url) . "'); }\n"
  ```
- **Zip injection without requiring new composer packages or PHP extensions.** Copy the static `woocommerce-piwik-analytics.zip` to a temp file in Matomo's tmp dir (`StaticContainer::get('path.tmp')`), add `woocommerce-piwik-analytics/config.php`, then stream the temp file with the existing `_readfile(...)` + headers and `unlink` it. Choose the writer at runtime:
  - **If the `zip` extension is present** (`class_exists('ZipArchive', false)`): use `\ZipArchive::addFromString(...)`. No new composer package.
  - **Otherwise** (Matomo's own `Unzip::factory` shows the `zip` extension is *not* assumed): use a minimal pure-PHP appender that writes a single **STORED** (uncompressed) local-file entry for `config.php` and rewrites the central directory. This needs only core `crc32()`, `pack()`, and string functions — no extension, no library. (The base zip is one we build ourselves, so a stored entry is safe/simple.) Encapsulate this in a small private helper (e.g. `appendStoredFileToZip($zipPath, $entryName, $contents)`), covered by its own unit test.
  - Keep the current no-compression streaming approach for the response itself.

### B4. Download page UI (`download.twig` + `Download.vue`)
- `download.twig`: pass `matomo-urls="{{ matomoUrls|json_encode }}"` to the Vue entry.
- `Download.vue`: add prop `matomoUrls: Array`. When length > 1, render a `<select>` bound to a `selectedUrl` data property (default first/current) with a label. When length ≤ 1, show the single URL as text. Append `&matomoUrl=<encodeURIComponent(selectedUrl)>` to the download link. Rebuild `vue/dist` via the project's Vue build.

### B5. Translations
Add keys for: the tracking-instance checkbox + description (WP plugin i18n / `.pot`), the "updates disabled" notice (WP), and the download-page host-select label (Matomo `lang/en.json`). Register any new client-side keys in `WooCommerceAnalytics.php::getClientSideTranslationKeys()`.

---

## Part C — Docs & housekeeping
- Update `thoughts/AS-606.md` to reflect the refined solution (const `WOOPIWIK_MATOMO_URL` + `config.php`, migration flags, tracking toggle default-on with fallback text field, admin notice, trusted-host dropdown, `ZipArchive` injection). *(Not edited during planning — done in implementation.)*
- Bump the WP plugin version in `woocommerce-piwik-analytics.php` header and in `Controller.php::pluginUpdate()` (`version` + `last_updated`), and add a `CHANGELOG.md` / `changes.json` entry, so the `ReleaseTest` release-recency check stays green.

---

## Testing / verification

**WP plugin unit tests** (`npm run test:wp`; add e.g. `tests/phpunit/WooPiwik/Admin/test-update-url.php`), using the tests-only instance override (`new Settings(false, 'https://trusted/…')`) to simulate the const without `define()`:
- `getUpdateBaseUrl()` → instance URL when const present; option URL when const absent + legacy allowed; `null` when const absent + fresh install.
- `getTrackingUrl()` → instance URL when bound; option URL when unbound.
- `maybeMigrateUpdateUrl()` sets `LEGACY_UPDATE_URL_ALLOWED` / `FIELD_USE_MATOMO_INSTANCE_URL` correctly for existing vs fresh installs, and runs only once.
- `WooPiwik::updateCheck()` registers no checker when `getUpdateBaseUrl()` is `null`.
- `Admin` adds the updates-disabled notice exactly when updates are disabled and the viewer is an admin.

**Matomo plugin tests** (`npm run phpunit --` from `matomo/`; add an Integration test):
- `buildCandidateMatomoUrls()` with 0 / 1 / many trusted hosts.
- `download()` rejects an untrusted `matomoUrl` (falls back to `getPiwikUrl()`); the produced zip contains `woocommerce-piwik-analytics/config.php` defining `WOOPIWIK_MATOMO_URL` = the chosen/validated URL (extract with Matomo's `Unzip` and assert).
- `buildConfigFileContents()` escapes correctly, guards with `!defined(...)`, and only emits a validated URL.
- `appendStoredFileToZip()` produces a valid archive readable by `Unzip` and containing the new entry — run this test path even when the `zip` extension is present so the pure-PHP fallback is always exercised.

**Matomo UI tests** (`tests/UI/`): the download/install page changes (host dropdown, resolved-URL display). Update `tests/UI/Woocommerce_spec.js` (and `WordPress_spec.js` if it renders the install page) to cover single-host vs multi-host rendering, and regenerate the affected expected screenshots (e.g. `Woocommerce_install_page.png`).

**Manual end-to-end** (`npm run compose up wordpress` for the WP side, Matomo dev env for the plugin side):
1. In Matomo, open the WooCommerceAnalytics install page → confirm the host dropdown appears only when multiple `trusted_hosts` are configured, else the single URL is shown.
2. Download → unzip → confirm `config.php` defines `WOOPIWIK_MATOMO_URL` to the selected trusted host.
3. Install in WP → confirm the Matomo URL field is hidden/disabled with tracking bound to the instance; toggle the checkbox off → field becomes editable and tracking uses it.
4. Change the `woopiwik_piwik_url` option directly (simulating the attack) → confirm the update checker still targets `WOOPIWIK_MATOMO_URL`, not the tampered value.
5. Define `WOOPIWIK_MATOMO_URL` in `wp-config.php` to a different value than the bundled `config.php` → confirm the `wp-config.php` value wins (guarded `!defined` in `config.php`) and drives both updates and tracking.
6. On a simulated fresh install with no `config.php` (and no `wp-config.php` const) → confirm the update checker is not registered and the admin notice shows.
