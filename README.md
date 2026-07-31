# Replace the Microsoft App Service WordPress image

A how-to for replacing the Microsoft App Service WordPress container
(`mcr.microsoft.com/appsvc/wordpress-debian-php`) with a container you build and patch yourself,
plus the files to do it.

The image serves the WordPress install that already exists on the App Service persistent share. It
does not install WordPress, and it never writes to `/home/site/wwwroot`. There is no database
migration and no file migration.

## What is here

| Path | Purpose |
|---|---|
| [docker/Dockerfile](docker/Dockerfile) | The image: PHP 8.4 + Apache, extensions, WP-CLI, sshd |
| [docker/entrypoint.sh](docker/entrypoint.sh) | Starts `sshd`, then hands off to `apache2-foreground` |
| [docker/conf/000-default.conf](docker/conf/000-default.conf) | Apache vhost for `/home/site/wwwroot` |
| [docker/conf/zz-wordpress.ini](docker/conf/zz-wordpress.ini) | PHP overrides, read after `php.ini` |
| [docker/conf/sshd_config](docker/conf/sshd_config) | App Service's SSH contract — port 2222 |
| [docker/conf/appservice-env.sh](docker/conf/appservice-env.sh) | Makes app settings visible to WP-CLI over SSH |
| [htaccess/](htaccess/) | `.htaccess` templates for the share — **not** part of the image |
| [bicep/site.bicep](bicep/site.bicep) | Trimmed App Service excerpt: the parts the swap touches |
| [.github/workflows/build-image.yml](.github/workflows/build-image.yml) | Builds in ACR, prints the digest to pin |
| [.github/dependabot.yml](.github/dependabot.yml) | Raises a PR when a new PHP base image ships |

Everything under `docker/` is the build context. The `.htaccess` templates live outside it
deliberately: they belong on the share, and changing them should not rebuild the image.

## Why

The Microsoft image is patched on Microsoft's cadence, not yours. As of January 2026 the newest tag
(`8.4_20260115.4.tuxprod`) shipped PHP 8.4.16, which is below the 8.4.21 that fixes
[CVE-2026-7261](https://nvd.nist.gov/vuln/detail/CVE-2026-7261) — a use-after-free in `SoapServer`
with a CVSS 3.1 base score of 9.8.

That particular CVE is not reachable from WordPress, and this image does not install `ext-soap` at
all, so the vulnerable code is absent rather than merely unused. The reason to move is the cadence,
not the single CVE: you cannot patch PHP when you choose to.

The Microsoft image is not deprecated and is still supported. This is a trade: you take on
responsibility for base-image updates in exchange for controlling when they happen.

## How it works

This is the fact that makes the swap cheap:

> The Microsoft image **installs** WordPress onto the persistent Azure Files share. This image only
> **serves** what is already there.

`WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'true'` mounts the share at `/home`, and WordPress core,
`wp-config.php`, plugins, themes and uploads all live under `/home/site/wwwroot`. Swapping the image
changes the PHP runtime and the web server in front of that directory and nothing else.

Two consequences worth internalising:

- **Rollback is cheap.** Neither image writes to the share on boot, so reverting the swap restores
  the previous runtime with nothing to migrate back. See [Rollback](#rollback).
- **An empty share fails loudly.** Because this image ships no WordPress, a blank or unmounted share
  produces a 403 rather than a silent fresh install.

## What the image contains

Built from `php:8.4-apache-bookworm`. See [docker/Dockerfile](docker/Dockerfile).

| Component | Detail |
|---|---|
| Web server | Apache with `mod_php`, not nginx + php-fpm ([why](#why-apache-and-not-nginx)) |
| PHP extensions | `bcmath exif gd intl mysqli opcache pdo_mysql zip` (plus the `php:8.4` defaults: `curl dom xml SimpleXML mbstring iconv`) |
| WP-CLI | 2.12.0 at `/usr/local/bin/wp` |
| SSH | `sshd` on port 2222, App Service's contract for the SCM tunnel |
| `ca-certificates` | Required if `wp-config.php` enables `MYSQLI_CLIENT_SSL` without a CA path — it then uses the system trust store |
| `default-mysql-client` | For `wp db` operations over SSH |

The PHP overrides are in [docker/conf/zz-wordpress.ini](docker/conf/zz-wordpress.ini).
`PHP_INI_SCAN_DIR` also includes `/home/site/ini`, so per-site overrides can be dropped on the share
without rebuilding.

> **Activate a `php.ini`.** The `php:8.4-apache` image ships `php.ini-production` and
> `php.ini-development` but enables neither, and the compiled-in defaults are the development ones:
> `display_errors = On`, `error_reporting = E_ALL`. Any PHP notice then renders into the page,
> leaking absolute filesystem paths to the public. The Dockerfile moves `php.ini-production` into
> place so errors are logged rather than displayed; the vhost points `ErrorLog` at `/dev/stderr`, so
> they reach the App Service log stream. Files in `conf.d` are read after `php.ini`, so the overrides
> above still win. WordPress cannot compensate for this — anything raised inside `wp-config.php`
> happens before `wp_debug_mode()` runs, and `WP_DEBUG = false` narrows `error_reporting` without
> touching `display_errors`.

**App settings do not reach SSH sessions.** App Service injects them into PID 1, but `sshd` builds a
fresh environment for each session rather than passing on its own. If `wp-config.php` reads
credentials through `getenv()`, WP-CLI over SSH fails with *Error establishing a database
connection* while the site itself is fine. The image ships
[conf/appservice-env.sh](docker/conf/appservice-env.sh) in `/etc/profile.d`, which re-exports the
settings it needs by reading `/proc/1/environ`. Nothing is written to disk, so the credentials stay
only in process memory.

### Why Apache and not nginx

The Microsoft image runs nginx + php-fpm, and staying on that stack is the obvious path. It is the
faster architecture. Three things outweigh that.

**WordPress expects `.htaccess`, and nginx silently ignores it.** WordPress and its plugins treat
`.htaccess` as a writable configuration surface: core writes the multisite rewrite rules there, and
caching, security and SSL plugins append their own blocks. Under nginx every one of those writes
succeeds and then does nothing. Expect to find a live `.htaccess` holding orphaned cache-plugin
blocks and *zero* routing rules. The equivalent nginx configuration has to live inside the image,
which means routing changes need an image rebuild and a redeploy, and the site's behaviour is split
between the share and the image. With Apache, the rules sit next to the site they belong to and
survive rebuilds untouched.

**HTTP Basic credentials do not reach PHP for free.** php-fpm does not forward the `Authorization`
header unless the FastCGI config explicitly passes it. It is a single missing line, easy to omit and
awkward to diagnose, and it breaks application passwords, REST Basic auth and Composer against a
private package repository. Apache exposes the header without special handling.

**One daemon instead of three.** nginx + php-fpm needs a process supervisor, two service configs and
a shared socket, plus `sshd` for App Service. `mod_php` collapses that to Apache and `sshd`,
runnable from a three-line entrypoint with no supervisor at all. Fewer components to patch and to
reason about when the container will not start.

**What it costs.** `mod_php` embeds the interpreter in every Apache worker, so memory scales with
concurrent connections rather than with PHP work, and it pins you to the prefork MPM — no threaded
or event MPM. Static assets are served less efficiently than nginx would. This is a real regression
in throughput per instance.

It is acceptable for a low-traffic site capped at a small instance count, where correctness and
maintainability matter more than concurrency. **On a public, high-traffic site that calculus
changes** — see [Adapting this](#adapting-this).

### The extension list is not arbitrary

Every extension maps to something the site actually runs. Derive the list from *your* site's
plugins — a missing extension does not degrade a feature, it white-screens the site. See
[Step 2](#step-2-derive-the-php-extension-list).

## Before you start

Do all of these **before** deploying. Several can only be done while the old container is still
running.

### Step 1: Confirm the deploy identity can push to ACR

An OIDC identity that has only ever run ARM deployments cannot push an image. It needs **AcrPush**
on the registry:

```sh
az role assignment list --assignee <AZURE_CLIENT_ID> \
  --scope $(az acr show -n <registry> --query id -o tsv) -o table
```

If `AcrPush` is absent the build fails with a 403 on first run.

### Step 2: Derive the PHP extension list

Get the authoritative plugin list from the running site. For multisite, scope it to the subsite —
network-active plugins alone will understate what is loaded:

```sh
wp plugin list --all --url=https://<site>/<subsite>/
```

Then map plugins to extensions. Common ones: `gd` for image handling, `zip` + `dom`/`xml` for
import/export and Excel generation, `intl` for locale handling, `bcmath` for calculations, `exif`
for uploads. Prefer `mysqli` and `pdo_mysql` together — WordPress uses `mysqli`, but some plugins
assume PDO.

### Step 3: Read `wp-config.php` on the share

This determines how much work the migration is. Check for:

- **Database credentials from the environment.** If it uses `getenv()`, the app settings carry over
  unchanged. If credentials are hardcoded, you have a different and larger problem.
- **Literal salts.** If `AUTH_KEY` and friends are literal strings, logged-in sessions survive the
  swap. If they are generated, everyone is logged out.
- **TLS to MySQL.** `define('MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL)` without a CA path means the
  system trust store is used, so `ca-certificates` in the image is sufficient. A pinned CA path means
  you must ship that file.
- **The `X-Forwarded-Proto` shim.** If TLS terminates upstream, `wp-config.php` must set
  `$_SERVER['HTTPS']`. The vhost also sets it, but the PHP-level shim is what most plugins read.
- **Multisite constants.** `MULTISITE`, `SUBDOMAIN_INSTALL`, `PATH_CURRENT_SITE`,
  `DOMAIN_CURRENT_SITE`. These drive the `.htaccess` rules you need.

> **Watch the `$http_protocol` ordering.** The `wp-config.php` the Microsoft image generates defines
> `DOMAIN_CURRENT_SITE` as `$http_protocol . $_SERVER['HTTP_HOST']` about eight lines *before*
> `$http_protocol` is assigned. PHP coerces the undefined variable to `""`, so multisite gets the
> bare hostname it needs and the site works — but each request raises an `E_WARNING`, invisible only
> because the Microsoft image suppresses display errors. Fix it by dropping the operand:
>
> ```php
> define( 'DOMAIN_CURRENT_SITE', $_SERVER['HTTP_HOST'] );
> ```
>
> That is byte-identical in effect and silences the warning. **Do not instead move the
> `$http_protocol` assignment above the `define`** — that changes `DOMAIN_CURRENT_SITE` to
> `https://host`, which breaks multisite routing. The variable is genuinely used further down, by
> `WP_HOME` and `WP_SITEURL`, so it cannot simply be deleted.

**Check `DB_CHARSET` but leave it alone.** It is often `utf8` while the database is `utf8mb4`.
Changing it risks mangling stored content, and it is unrelated to the image swap.

### Step 4: Write the `.htaccess`

This is the step most likely to be forgotten, because under nginx it had no effect.

See [The `.htaccess`](#the-htaccess) below. Stage the file before cutover — the moment Apache
starts, `.htaccess` becomes live.

### Step 5: Verify the web user can write

Apache runs as `www-data` (uid 33). Confirm uploads and plugin installs will still work:

```sh
su -s /bin/sh www-data -c 'touch /home/site/wwwroot/wp-content/.probe && rm /home/site/wwwroot/wp-content/.probe'
```

### Step 6: Back up

The database should be backed up through Azure. For files, write the archive **outside** the
document root — under Apache, `/home/site/wwwroot` is served, so a tarball there is downloadable:

```sh
mkdir -p /home/backups
tar -czf /home/backups/wp-content-$(date +%Y%m%d).tar.gz -C /home/site/wwwroot wp-content
```

Delete these after a successful cutover.

## The `.htaccess`

Under nginx, `.htaccess` was inert. Two things follow.

**Without WordPress rules, routing breaks.** Apache serves a directory listing or a 404 instead of
handing the request to `index.php`. Deploy the matching template from [htaccess/](htaccess/) to
`/home/site/wwwroot/.htaccess`:

- [wordpress-multisite-subdirectory.htaccess](htaccess/wordpress-multisite-subdirectory.htaccess)
- [wordpress-single.htaccess](htaccess/wordpress-single.htaccess) — single site or subdomain
  multisite

**Dormant directives wake up.** A file left over from a since-deactivated cache plugin may contain:

```apache
Header set Access-Control-Allow-Origin "*"
```

Inert under nginx. Live under Apache, because the image enables `mod_headers`. Audit every directive
in the existing file rather than preserving it wholesale.

### The rules that matter

```apache
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
```

Without this, PHP may not see the `Authorization` header and every HTTP Basic request — application
passwords, REST clients, `composer require` against a private repository — returns 401.

```apache
RewriteRule ^([_0-9a-zA-Z-]+/)?(wp-(content|admin|includes).*) $2 [L]
RewriteRule ^([_0-9a-zA-Z-]+/)?(.*\.php)$ $2 [L]
```

The optional `^([_0-9a-zA-Z-]+/)?` group is what makes subdirectory multisite work — it strips the
site prefix so `/subsite/wp-admin/` resolves to the shared `wp-admin`. Use these rules only for
**subdirectory** multisite; subdomain installs and single sites need the simpler standard block.

## App settings

Keep these — `wp-config.php` reads them via `getenv()`:

| Setting | Source |
|---|---|
| `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD` | Key Vault references |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | Must stay `'true'` — this mounts the share |
| `WP_MEMORY_LIMIT`, `WP_MAX_MEMORY_LIMIT` | Read by WordPress |
| `PHP_INI_SCAN_DIR` | Adds `/home/site/ini` for per-site overrides |
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | Can be reduced; this image starts far faster |

Remove these — they were consumed by the Microsoft image's bootstrap and mean nothing to a plain PHP
container:

- Blob storage: `STORAGE_ACCOUNT_NAME`, `STORAGE_ACCOUNT_KEY`, `BLOB_CONTAINER_NAME`,
  `BLOB_STORAGE_URL`, `BLOB_STORAGE_ENABLED`
- Bootstrap: `WORDPRESS_ADMIN_USER`, `WORDPRESS_ADMIN_PASSWORD`, `WORDPRESS_ADMIN_EMAIL`,
  `WORDPRESS_TITLE`, `WORDPRESS_LOCALE_CODE`, `WORDPRESS_MULTISITE_TYPE`,
  `WORDPRESS_MULTISITE_CONVERT`
- Runtime knobs now set in the image's `.ini`: `UPLOAD_MAX_FILESIZE`, `POST_MAX_SIZE`
- Others: `SETUP_PHPMYADMIN`, `WORDPRESS_LOCAL_STORAGE_CACHE_ENABLED`, `WP_EMAIL_CONNECTION_STRING`

If `wp-config.php` derives `WP_HOME`, `WP_SITEURL` and `DOMAIN_CURRENT_SITE` from the request host
at runtime, drop them as app settings too — they are redundant there and can conflict.

> Check the old values before copying them: `upload_max_filesize` at 512M with `post_max_size` at
> 256M is inverted, so uploads are silently capped at the smaller number. `post_max_size` must
> always be greater than or equal to `upload_max_filesize`.

## Deploying

Image builds and infrastructure deploys are **separate workflows with separate concurrency groups**.
Merging both at once races them and deploys a tag that does not exist yet. Ship in two steps.

Configure first:

| Kind | Name | Value |
|---|---|---|
| Variable | `REGISTRY_NAME` | Your ACR name |
| Variable | `IMAGE_NAME` | Optional, defaults to `wordpress` |
| Secret | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | The OIDC federated identity |

The workflow no-ops when those are absent, so a fork does not fail on every push.

### Step 1: the image

Merge the PR containing `docker/**`. It touches no infrastructure path, so nothing deploys. The
workflow publishes `<image>:<commit-sha>`, resolves it to a digest, and prints the parameter line in
the job summary and in the log.

Images are tagged by commit SHA, never `latest`, so every build is traceable to a commit — but
deployments pin the **digest**, which is immutable even if a tag is later overwritten.

### Step 2: the infrastructure

Pin the digest, copying the line from the build job summary:

```bicep
param imageVersion = 'sha256:<64-hex>'
```

Give the parameter no default, so a deploy cannot silently fall back to a floating tag.
[site.bicep](bicep/site.bicep) also accepts a plain tag — it composes the reference with `@` for
digests and `:` for tags.

Then merge. Check the `what-if` output before approving. The site should appear under **Modify**.
The `kind` change from `app,linux` to `app,linux,container` is the one to watch — if it shows as
Create or Delete, stop.

### Step 3: smoke test

If the site sets `publicNetworkAccess: 'Disabled'`, every deployment closes public access to both
the app and its SCM/Kudu site — including portal SSH. Re-open it under App Service → Networking →
Access restrictions: set **App access** to Enabled, then add your own IP under **Site access**. A
private endpoint does not block this; public access and a private endpoint can coexist. Do the same
on the **Advanced tool site** tab if you need portal SSH. On Linux sites, toggling app access
restarts the app — wait for it to come back before testing.

In this order, because each step depends on the previous one working:

1. The front page loads.
2. `/wp-admin/` authenticates. **If a 2FA plugin is network-active, have a recovery path ready
   before you start.**
3. `/wp-admin/network/` loads, for multisite.
4. An HTTP Basic client succeeds — application password, REST call or `composer require`.
5. An export that exercises `zip`, XML and `gd`.
6. A test email actually arrives.

### Step 4: clean up

Delete the backup tarballs and remove plugins that only existed for the old platform. Leave this
until the new image has run long enough to trust — it is the one step `git revert` cannot undo.

## Updating PHP

This is the point of the exercise:

1. Dependabot raises a PR bumping the `FROM` digest when a new `php:8.4-apache-bookworm` is
   published. Configured in [.github/dependabot.yml](.github/dependabot.yml).
2. Merge it. The change is under `docker/**`, so the build workflow fires on the path filter,
   publishes a new image and prints its digest.
3. Copy that digest into `imageVersion` and merge.

The `FROM` line carries both a tag and a digest. The digest is what is actually pulled, so
rebuilding an old commit resolves the base image that commit was built against. The tag is there so
Dependabot knows which stream to follow, and so the line is readable.

Only the digest moves automatically. Dependabot is configured to ignore major and minor bumps of
`php`, because it will otherwise rewrite the tag — its first run will propose 8.4 → 8.5. Moving to a
new PHP minor is a WordPress and plugin compatibility decision: edit the tag by hand, drop the stale
digest, and let the build resolve the new one.

To rebuild without waiting for upstream — a changed `.ini`, a WP-CLI bump, or just to prove the
image still builds — re-run the last run from Actions → **Build and push container image** →
**Re-run all jobs**. The workflow has no `workflow_dispatch`: every image tag is a commit SHA that
exists in history, and a re-run rebuilds that same tree under that same tag.

> An ACR Task with `--base-image-trigger-enabled` would rebuild inside the registry instead. It was
> rejected: it needs a floating tag in `FROM`, it builds outside the pipeline's OIDC identity and
> its PR checks, and it still only automates the rebuild — someone has to notice and pin the digest
> either way. Dependabot raises that notice where the review already happens.

## Rollback

Revert the merge commit and deploy:

```sh
git revert -m 1 <merge-commit>
```

Revert the whole change, not just `linuxFxVersion` — a partial revert leaves the Microsoft image
running without the app settings, `kind` and parameters the swap removed.

Rollback is cheap because neither image writes to the share on boot: the database, `wp-config.php`,
plugins, themes and uploads are untouched by the swap, so there is nothing to restore. The
`.htaccess` can stay — nginx ignores it.

The one thing that makes rollback harder is [Step 4: clean up](#step-4-clean-up). Deleting the
old-platform plugins and the backup tarballs is not covered by a `git revert`.

In a genuine outage you can set `linuxFxVersion` back from the portal to get serving again in a
couple of minutes, but treat that as first aid only — the next deployment re-applies the template.

## Adapting this

The procedure holds for any site on the Microsoft WordPress image, but these need re-deciding:

| Decision | Why it may differ |
|---|---|
| Apache vs nginx + php-fpm | `mod_php` trades throughput for `.htaccess` support and simplicity. On a public, high-traffic site, or one scaled beyond a single instance, reconsider — the `.htaccess` rules would then have to be translated into the image's nginx config |
| PHP extension list | Derive from *that* site's plugins ([Step 2](#step-2-derive-the-php-extension-list)) |
| `.htaccess` rules | Subdirectory multisite, subdomain multisite and single site all differ |
| `HTTP_AUTHORIZATION` rule | Only needed where something authenticates with HTTP Basic |
| Blob-storage settings | A site serving uploads from the share does not need them. A site using the Azure Storage plugin does, and the plugin needs its own configuration |
| Memory and upload limits | Read from the current site rather than copied from here |
| `healthCheckPath` | `/` works only if the site returns 200 there. Prefer a dedicated endpoint |
| Registry and identity | Each environment has its own registry, managed identity and AcrPull assignment |

The parts that carry over unchanged: the share-serving model, the SSH-on-2222 requirement, the
app-settings split, and the two-step deploy ordering.

## Known gaps

- **No copy-if-empty bootstrap.** If the share is ever lost, the image cannot rebuild the site — it
  has no WordPress in it. Restoring means restoring the share. This is a deliberate trade for the
  guarantee that nothing overwrites `/home/site/wwwroot`, but it is a real DR gap.
- **`root:Docker!`** is baked in, per App Service's SSH contract. It is reachable only through the
  platform's authenticated SCM tunnel, never from the network — but it is a fixed credential in an
  image, and it is worth knowing that.
- **The SSH config must offer a CBC cipher and a SHA-1 MAC.** App Service's portal SSH client
  requires one of `aes128-cbc`/`3des-cbc`/`aes256-cbc` and one of `hmac-sha1`/`hmac-sha1-96`, so
  scanners will flag it. Keep only the strongest permitted of each and offer GCM/CTR and SHA-2 ahead
  of them. Removing them entirely breaks portal SSH, which is the only file-level access to the
  share.
- **The digest pin is manual.** Dependabot notices a new base image and merging its PR builds one,
  but nothing writes `imageVersion` — a human opens that PR. That is deliberate: it keeps a
  deployment gate on every image change.

## License

MIT. See [LICENSE](LICENSE).
