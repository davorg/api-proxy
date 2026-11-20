# Repository review and confirmed issues

Reviewed on 20 November 2026 at commit
`a3689bc5f98bd18f559b1be8d98b0454fb339f0e`. This review adds documentation and
files issues; it does not change application behavior.

## Validation

The installed environment was Perl 5.42.3, Dancer2 2.2.1,
Dancer2::Plugin::Cache::CHI 2.0.1 and CHI 0.61.

| Check | Result |
| --- | --- |
| `prove -IAPIProxy/lib -lv APIProxy/t` | Failed: module-load assertion passed; both route test files aborted because `Dancer2::Template::Simple` was missing |
| `prove -Ilib -lv t` from `APIProxy/` | Same template-engine failure |
| `perl -c app_service` | Syntax OK with installed dependencies; daemon was not started |
| `perl -IAPIProxy/lib -c APIProxy/bin/app.psgi` | Syntax OK; this does not initialize all runtime components |
| Isolated PSGI diagnostics with dummy credentials and mocked upstream | Reproduced cache, encoding, redirect, exception, error-format and query defects listed below |

The Simple engine was removed from Dancer2 core in 2.0.0, as recorded in the
installed Dancer2 changelog, and is available as a
[separate CPAN distribution](https://metacpan.org/pod/Dancer2::Template::Simple).
The manifests permit Dancer2 2.x without declaring that engine. This is a
dependency compatibility failure, not evidence that Google rejected a request.

To inspect routes beyond that first blocker, diagnostic processes used
`APIProxy::set(template => 'tiny')` before `APIProxy->to_app`. This temporary
override was not written into the repository and is not a proposed template fix:
the existing `<% ... %>` expressions remain literal with Tiny. Except for the
missing-driver reproduction, diagnostics also replaced `APIProxy::cache` with an
isolated `CHI->new(driver => 'Memory', global => 0)` instance. This bypassed the
second blocker without changing production configuration.

Upstream responses were supplied by replacing `LWP::UserAgent::get` in the
diagnostic process, with `GOOGLE_MAPS_API_KEY` scoped to `review-placeholder`.
Tests used `Plack::Test` and performed no real provider requests. The existing
Google Maps test was also run with the key explicitly unset after the template
override: it returned 400 and failed two of its four assertions.

These checks establish behavior of the repository code with the stated
dependencies. Real Google Maps rendering, provider key restrictions, daemon
startup, CGI/FastCGI deployment and a clean dependency installation were not
validated.

## Filed issues

Each issue includes source links at the reviewed commit, reproduction evidence,
a suggested fix and acceptance criteria. The existing general review issue
[#3](https://github.com/davorg/api-proxy/issues/3) remains open; the original route
request [#1](https://github.com/davorg/api-proxy/issues/1) was already closed.

| Issue | Confirmed problem | Evidence |
| --- | --- | --- |
| [#4 Dependencies](https://github.com/davorg/api-proxy/issues/4) | Three inconsistent dependency definitions omit runtime, template, HTTPS, service and test requirements | Route tests abort under allowed Dancer2 2.2.1 because Simple is missing; imports disagree with manifests |
| [#5 Cache configuration](https://github.com/davorg/api-proxy/issues/5) | Caching is enabled with no CHI driver | A valid query and dummy key yield 500, `missing required param 'driver' or 'driver_class'`, before any upstream call |
| [#6 Cached response headers](https://github.com/davorg/api-proxy/issues/6) | Cache hits omit Content-Type and CORS setup | Mock application/json response becomes text/html on the second request; wildcard CORS disappears; upstream call count stays at one |
| [#7 HTTP content encoding](https://github.com/davorg/api-proxy/issues/7) | Compressed upstream content is returned as undecoded, altered bytes without Content-Encoding | Gzip fixture produces a binary HTML response with no encoding header; its initial bytes change from `1f8b` to `1fc28b` |
| [#8 Redirect limits](https://github.com/davorg/api-proxy/issues/8) | Manual redirects bypass LWP's bounded redirect chain | A guarded mock produces 20 redirects then success; a single route request performs all 21 get calls |
| [#9 Exception control flow](https://github.com/davorg/api-proxy/issues/9) | Returning inside catch does not exit the route | A thrown get exception is followed by an `is_redirect` call on an undefined response |
| [#10 Error responses](https://github.com/davorg/api-proxy/issues/10) | Messages become opaque hash strings; upstream outages are classified as client errors | Unknown API and missing q yield `HASH(...)`; mocked upstream 503 becomes local 400 |
| [#11 Query encoding](https://github.com/davorg/api-proxy/issues/11) | Input normalization changes valid searches and validates emptiness incorrectly | AT&T becomes AT T, C++ becomes C followed by a space, whitespace is accepted and `0` is rejected |
| [#12 Test isolation](https://github.com/davorg/api-proxy/issues/12) | Google Maps test depends on external configuration and potentially live HTTP | With no key it expects 200 but receives 400; the test sets up neither a fake key nor upstream/cache fixtures |

## Suggested fix order

1. Reconcile dependency declarations and ensure the configured template engine
   loads ([#4](https://github.com/davorg/api-proxy/issues/4)). Make the default
   tests independent of credentials, network access and persistent caches
   ([#12](https://github.com/davorg/api-proxy/issues/12)).
2. Supply working cache configuration
   ([#5](https://github.com/davorg/api-proxy/issues/5)). This is the next blocker
   for all valid requests to the only configured API.
3. Correct response encoding and cache headers
   ([#7](https://github.com/davorg/api-proxy/issues/7),
   [#6](https://github.com/davorg/api-proxy/issues/6)) so successful requests
   consistently return usable content.
4. Bound redirects and terminate after caught failures
   ([#8](https://github.com/davorg/api-proxy/issues/8),
   [#9](https://github.com/davorg/api-proxy/issues/9)), then correct error
   serialization/status mapping and query encoding
   ([#10](https://github.com/davorg/api-proxy/issues/10),
   [#11](https://github.com/davorg/api-proxy/issues/11)).

Add regression coverage as each defect is fixed. Keep live-provider integration
checks separate from the default suite.

## Dependency follow-up

The dependency setup for [#4](https://github.com/davorg/api-proxy/issues/4) now
uses `APIProxy/cpanfile` as its authoritative list. The root cpanfile loads it,
and `Makefile.PL` derives package prerequisites and optional features from it.
Template Toolkit replaces Simple with the existing `<% ... %>` delimiters.
The original review results and issue table above describe the reviewed commit.

A fresh self-contained installation of runtime, test, configuration and
development dependencies plus the `service` and `fcgi` features installed 116
distributions. Dependency tests were skipped during that installation; the
application checks below ran afterward with non-core global modules excluded.
The resulting environment used Perl 5.42.3, Dancer2 2.3.0 and Template 3.106.

- The PSGI entry point loads and selects Template Toolkit.
- All six module-load and index assertions pass, including title/content
  rendering and absence of unexpanded template expressions.
- HTTPS, service and FastCGI dependencies load; the service and dispatcher
  scripts compile without starting a daemon or contacting Google.
- Root and application manifests, and generated distribution metadata, agree
  across prerequisite phases and optional features.
- The full suite runs all ten assertions. Only the two Google Maps success
  assertions fail with the key unset, as tracked in
  [#12](https://github.com/davorg/api-proxy/issues/12).
