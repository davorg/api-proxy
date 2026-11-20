# api-proxy

A small Perl [Dancer2](https://metacpan.org/pod/Dancer2) application that
proxies configured upstream APIs through a PSGI application. The checked-in
configuration exposes Google Maps Embed search and Last.fm top artists.

The current checkout has confirmed caching and HTTP response defects.
See the [review and issue list](docs/review.md) before deploying it. The commands
below describe the existing entry points; they do not imply that the current
test suite passes or that all proxy requests work.

## Repository layout

| Path | Purpose |
| --- | --- |
| `APIProxy/lib/APIProxy.pm` | Routes, parameter handling, HTTP client, caching and request logging |
| `APIProxy/apis.yml` | Checked-in API definitions; override its path with `APIPROXY_APIS_FILE` |
| `APIProxy/bin/app.psgi` | Loads the application and returns its PSGI callable |
| `APIProxy/config.yml` | Shared Dancer settings, including template engine and reverse-proxy support |
| `APIProxy/environments/` | Development and production logging/error settings |
| `APIProxy/views/`, `APIProxy/public/` | Landing page templates, static assets and CGI/FastCGI entry points |
| `APIProxy/t/` | Module-load, index-route and Google Maps route tests |
| `app_service` | Daemon::Control wrapper around `/usr/bin/starman` |
| `Dockerfile`, `bin/`, `.github/workflows/` | Cloud Run container, build/deploy scripts and workflows; see [DEPLOY.md](DEPLOY.md) |
| `APIProxy/cpanfile` | Authoritative runtime, test, configuration and optional feature dependencies |
| `cpanfile` | Loads the application dependency list for installation from the repository root |
| `APIProxy/Makefile.PL` | Generates package prerequisites from the application cpanfile |

Read [the architecture notes](docs/architecture.md) for request flow, configuration,
logging and extension points.

## Install dependencies

Use Perl 5.14 or newer and `cpanm`, preferably with a project-specific local
library. The application declares Dancer2 1.1.2 or newer and explicitly installs
its template engine, including when using Dancer2 2.x. From the repository root:

```sh
cpanm --installdeps --with-configure .
```

This installs the declared runtime, test and configuration dependencies,
including HTTPS support. For additional development tools, add `--with-develop`.
For the optional `app_service` wrapper, enable the `service` feature:

```sh
cpanm --installdeps --with-configure --with-feature=service .
```

The application uses Dancer2's Template Toolkit engine and explicitly declares
its `Template` dependency. The configured `<% ... %>` delimiters preserve the
existing templates on Dancer2 1.x and 2.x without requiring the retired Simple
engine.

Both commands can also run from `APIProxy/`: the root cpanfile loads the same
authoritative list. The legacy FastCGI dispatcher additionally needs the `fcgi`
feature (`--with-feature=fcgi`); CGI needs no extra feature. The existing
`accelerate` feature remains available for optional XS modules. To use an
isolated local library:

```sh
cpanm --local-lib-contained local --installdeps --with-configure --with-feature=service .
export PERL5LIB="$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"
export PATH="$PWD/local/bin:$PATH"
```

Choose the installation directory to suit the deployment and keep it out of
version control. Check that the Starman executable is at `/usr/bin/starman`
before using `app_service`; that path is hardcoded and a local-library install
places its executable under `local/bin` instead. The remaining HTTP response
issues are recorded in the review.

## Run locally

From the repository root, export the keys for the APIs you want to call and
start the PSGI application:

```sh
export GOOGLE_MAPS_API_KEY='your-api-key'
export LASTFM_API_KEY='your-lastfm-api-key'
plackup -I APIProxy/lib -p 5000 APIProxy/bin/app.psgi
```

`plackup` and `app.psgi` do **not** load `.env`. Only `app_service` loads it.
The key is checked when handling an API request, so it is not needed simply to
load the module or render the landing page.

With a running, configured instance:

```sh
curl -i http://127.0.0.1:5000/
curl -i --get --data-urlencode 'q=Clapham Common' http://127.0.0.1:5000/gmap_search
curl -i --get --data-urlencode 'method=user.gettopartists' \
  --data-urlencode 'user=davorg' --data-urlencode 'period=7day' \
  --data-urlencode 'limit=5' --data-urlencode 'format=json' \
  http://127.0.0.1:5000/lastfm/
```

The second command makes a real upstream request on a cache miss and requires a
key accepted by Google Maps Embed. The Last.fm request requires `LASTFM_API_KEY`.
Repeated requests in the same worker use the cached successful body for up to
five minutes.

## Routes

| Request | Current behavior |
| --- | --- |
| `GET /` | Renders the informational landing page |
| `GET /gmap_search?q=...` | Fetches Google Maps Embed search HTML using `GOOGLE_MAPS_API_KEY` |
| `GET /lastfm/?method=user.gettopartists&user=...&period=...&limit=...&format=json` | Fetches Last.fm JSON using `LASTFM_API_KEY` |
| `GET /<unknown-api>` | Returns a JSON error with status 404 |
| Missing or whitespace-only required parameter | Returns a JSON error with status 400; the string `0` is valid |
| Missing key for a configured API | Returns a JSON error with status 500 |
| Upstream HTTP failure | Returns a JSON error with status 502; upstream timeouts use 504 |
| Upstream transport exception | Returns a JSON error with status 502, or 504 when the failure reports a timeout |
| Upstream redirect chain over five hops | Returns a JSON error with status 502; shorter absolute and relative redirects are followed by LWP |
| Unsupported or invalid upstream content encoding | Returns a JSON error with status 502 |

Error responses use `Content-Type: application/json` and the same wildcard CORS
header as successful responses. Fresh and cached successful responses both use
the upstream Content-Type and wildcard CORS. The string `0` is a valid
parameter value; whitespace-only values are rejected.

The proxy advertises only content encodings supported by its installed
`HTTP::Message` decoder. It decodes upstream content before caching or returning
it, and reports unsupported or malformed encodings as a 502 response.

## Configuration and service operation

The checked-in `APIProxy/apis.yml` defines the `gmap_search` and `lastfm` APIs. Set
`APIPROXY_APIS_FILE` to load API definitions from another YAML file; the file
must contain a mapping from API names to `params`, `url`, and `key` fields, with
optional `cache` and `timeout` fields. Definitions are loaded and validated at
process startup. The key field names an environment variable, such as
`GOOGLE_MAPS_API_KEY` or `LASTFM_API_KEY`; keep secret values out of the YAML
file. The 300-second
cache TTL remains in `APIProxy.pm`. `APIProxy/config.yml` configures CHI's
[Memory driver](https://metacpan.org/pod/CHI::Driver::Memory) with `global: 0`,
giving the application a private cache in each process.

The same cache configuration applies in development and production. No cache
directory, filesystem permissions or external cache service is required.
Starman workers do **not** share cache entries: each worker may fetch a query
once during its own five-minute cache window. Entries disappear when a worker
restarts. For a deployment that needs sharing across workers, override the
`plugins` / `Cache::CHI` settings with a shared backend and provide its storage
and permissions explicitly; `global: 1` on the Memory driver does not share data
across processes.

The service wrapper reads `.env` from its working directory. Create an untracked
`.env` in the repository root with values appropriate to the host:

```dotenv
GOOGLE_MAPS_API_KEY=your-api-key
LASTFM_API_KEY=your-lastfm-api-key
PROXY_APP_NAME=api-proxy
PROXY_OWNER=your-service-user
PROXY_GROUP=your-service-group
PROXY_LOG_DIR=/path/to/writable/log-directory
PROXY_APP_PORT=5000
PROXY_WORKER_COUNT=2
PROXY_APP_PRELOAD=1
DANCER_ENVIRONMENT=production
```

| Variable | Service behavior |
| --- | --- |
| `PROXY_APP_NAME` | Service name and `/var/run/<name>.pid` filename |
| `PROXY_OWNER`, `PROXY_GROUP` | Account and group used by Daemon::Control |
| `PROXY_LOG_DIR` | Directory for `error.log` and `output.log` |
| `PROXY_APP_PORT` | Adds Starman `-l :<port>` when set |
| `PROXY_WORKER_COUNT` | Adds Starman `--workers <count>` when set |
| `PROXY_APP_PRELOAD` | Any nonempty value other than `0` adds `--preload-app`; use empty or `0` to disable |
| `DANCER_ENVIRONMENT` | Selects Dancer's environment; the wrapper does not force production |
| `APIPROXY_APIS_FILE` | Optional path to a YAML file containing API definitions; defaults to `APIProxy/apis.yml` |

The service identity and filesystem paths have no application-provided defaults.
Prepare the account, log directory and PID-file permissions for the deployment.
Run the wrapper from the repository root so its relative paths and `.env` resolve
consistently:

```sh
perl ./app_service start
perl ./app_service status
perl ./app_service stop
```

For a foreground production process, use the same PSGI entry point directly:

```sh
DANCER_ENVIRONMENT=production starman --workers 2 --listen :5000 APIProxy/bin/app.psgi
```

Export `GOOGLE_MAPS_API_KEY` separately for this command. Production selects the
file logger and hides stack traces; the application also writes request records
to stderr. `behind_proxy: true` is enabled in the shared config, so configure
the deployment's reverse proxy and forwarded headers deliberately.

## Versioning

The release version lives in [`APIProxy/lib/APIProxy.pm`](APIProxy/lib/APIProxy.pm)
and starts at `1.0.0`. Use SemVer `MAJOR.MINOR.PATCH` when preparing releases.
Published container tags include that version and the source commit, for
example `api-proxy:1.0.0-<full-commit-SHA>`. The build script also sets the image's
`org.opencontainers.image.version` label. See [DEPLOY.md](DEPLOY.md#versioning)
for the release and tagging rules.

## Google Cloud Run

The Cloud Run deployment targets `https://proxy.davecross.co.uk` and follows the
`feeds` build/deploy pattern. Pull requests test the container; successful
`main` builds publish to Artifact Registry and deploy by immutable image digest
with Workload Identity Federation. The API key is supplied from Secret Manager.

See [DEPLOY.md](DEPLOY.md) for Google Cloud and GitHub setup, the one-time custom
domain/DNS steps, local container commands and rollback. The Cloud Run container
uses a non-root Starman process, honours `PORT`, and logs to stdout/stderr.

## Tests

From the repository root:

```sh
prove -IAPIProxy/lib -lv APIProxy/t
prove -lv t/deployment_scripts.t
```

The default suite needs no API key or outbound HTTP. The index test checks title
and page rendering. The Google Maps route test scopes a dummy key, supplies
fixture HTML through a mocked HTTP client, and uses a private in-memory cache.
It verifies validation, upstream URL construction, cache hits and a fresh fetch
after clearing the test cache. A transport guard fails any unexpected HTTP
request locally. Host credentials and deployment cache contents do not affect
these tests.

A separate regression test loads the checked-in cache configuration without
overriding its plugin settings. It checks fresh and cached responses, separation
from unrelated caches, and the 300-second expiration boundary using CHI's test
clock rather than sleeping.

A separate live-provider smoke test is available under `APIProxy/xt/`. It skips
unless explicitly enabled and requires an exported real key:

```sh
API_PROXY_LIVE_TESTS=1 prove -IAPIProxy/lib -lv APIProxy/xt/gmap_search_live.t
```

This command contacts Google and can consume API quota. The live check uses a
private memory cache and does not validate production cache configuration.
Existing upstream handling defects may still cause it to fail. To check that
the live test skips by default alongside the offline suite:

```sh
prove -IAPIProxy/lib -lv APIProxy/t APIProxy/xt
```

The [review](docs/review.md) records the actual test result, diagnostic overrides,
reproduced defects and suggested order of fixes.
