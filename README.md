# api-proxy

A small Perl [Dancer2](https://metacpan.org/pod/Dancer2) application that fetches
Google Maps Embed search responses using a server-side API key. It exposes one
configured API, `gmap_search`, through a PSGI application. It returns upstream
HTML rather than a structured places-search JSON result.

The current checkout has confirmed startup, caching and HTTP response defects.
See the [review and issue list](docs/review.md) before deploying it. The commands
below describe the existing entry points; they do not imply that the current
test suite passes or that all proxy requests work.

## Repository layout

| Path | Purpose |
| --- | --- |
| `APIProxy/lib/APIProxy.pm` | Routes, API registry, parameter handling, HTTP client, caching and request logging |
| `APIProxy/bin/app.psgi` | Loads the application and returns its PSGI callable |
| `APIProxy/config.yml` | Shared Dancer settings, including template engine and reverse-proxy support |
| `APIProxy/environments/` | Development and production logging/error settings |
| `APIProxy/views/`, `APIProxy/public/` | Landing page templates, static assets and CGI/FastCGI entry points |
| `APIProxy/t/` | Module-load, index-route and Google Maps route tests |
| `app_service` | Daemon::Control wrapper around `/usr/bin/starman` |
| `cpanfile` | Root proxy dependencies and development dependencies |
| `APIProxy/cpanfile`, `APIProxy/Makefile.PL` | Additional, currently inconsistent application dependency/package metadata |

Read [the architecture notes](docs/architecture.md) for request flow, configuration,
logging and extension points.

## Install dependencies

Use Perl and `cpanm`, preferably with a project-specific local library. From the
repository root, install both sets of declared dependencies:

```sh
cpanm --installdeps --with-develop .
cpanm --installdeps ./APIProxy
```

The manifests are incomplete ([#4](https://github.com/davorg/api-proxy/issues/4)).
These additional direct dependencies cover the configured template engine,
HTTPS transport and test imports:

```sh
cpanm Dancer2::Template::Simple LWP::Protocol::https Plack HTTP::Request::Common Ref::Util
```

`Dancer2::Template::Simple` is a
[separate distribution](https://metacpan.org/pod/Dancer2::Template::Simple)
for Dancer2 2.x. The existing templates use its `<% ... %>` syntax; changing only
`template: simple` to `template: tiny` is not a complete migration.

For the optional service wrapper, also install:

```sh
cpanm Daemon::Control ENV::Util Starman
```

Check that the Starman executable is actually at `/usr/bin/starman` before using
`app_service`; that path is hardcoded. Installing the modules does not resolve
the missing cache configuration or the other runtime issues in the review.

## Run locally

From the repository root, export the key into the process environment and start
the PSGI application:

```sh
export GOOGLE_MAPS_API_KEY='your-api-key'
plackup -I APIProxy/lib -p 5000 APIProxy/bin/app.psgi
```

`plackup` and `app.psgi` do **not** load `.env`. Only `app_service` loads it.
The key is checked when handling an API request, so it is not needed simply to
load the module or render the landing page.

With a running, configured instance:

```sh
curl -i http://127.0.0.1:5000/
curl -i --get --data-urlencode 'q=Clapham Common' http://127.0.0.1:5000/gmap_search
```

The second command makes a real upstream request on a cache miss and requires a
key accepted by Google Maps Embed. With the checked-in cache configuration, a
key-bearing request currently fails before reaching Google
([#5](https://github.com/davorg/api-proxy/issues/5)).

## Routes

| Request | Current behavior |
| --- | --- |
| `GET /` | Renders the informational landing page |
| `GET /gmap_search?q=...` | Validates `q` and the environment key, checks cache, then fetches Google Maps Embed search HTML |
| `GET /<unknown-api>` | Sets status 404 |
| Missing or false `q` | Sets status 400; the string `0` is incorrectly treated as missing |
| Missing `GOOGLE_MAPS_API_KEY` | Sets status 400, even though this is server configuration |
| Non-successful upstream response | Sets status 400, including upstream server failures |

Error helpers intend to return `{ error => message }`, but there is no configured
serializer, so clients currently receive an opaque `HASH(...)` body. Fresh
successful upstream responses copy `Content-Type` and add
`Access-Control-Allow-Origin: *`; cached responses skip those headers. See
[#6](https://github.com/davorg/api-proxy/issues/6) and
[#10](https://github.com/davorg/api-proxy/issues/10).

## Configuration and service operation

The application requires `GOOGLE_MAPS_API_KEY` for its only API. API definitions,
the 300-second cache TTL and 30-second HTTP timeout are in `APIProxy.pm`, rather
than environment variables. There is currently no configured cache driver.

The service wrapper reads `.env` from its working directory. Create an untracked
`.env` in the repository root with values appropriate to the host:

```dotenv
GOOGLE_MAPS_API_KEY=your-api-key
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

## Tests

From the repository root:

```sh
prove -IAPIProxy/lib -lv APIProxy/t
```

The three files declare seven assertions in total. The Google Maps route test
currently has no dummy key, mocked upstream or isolated cache: it fails without
a key and can contact Google if configured. Avoid supplying a real key for
routine tests; making the suite independent of credentials and network access
is tracked in [#12](https://github.com/davorg/api-proxy/issues/12).

The [review](docs/review.md) records the actual test result, diagnostic overrides,
reproduced defects and suggested order of fixes.
