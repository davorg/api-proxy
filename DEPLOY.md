# Deploy api-proxy to Google Cloud Run

The deployment follows [davorg/feeds](https://github.com/davorg/feeds/blob/main/DEPLOY.md):
two scripts build/push a container and deploy it, and two GitHub Actions
workflows test, publish and deploy by immutable image digest. The target is
`https://proxy.davecross.co.uk`.

| Setting | Default |
| --- | --- |
| Project | Set `GCP_PROJECT_ID` in GitHub; existing services use `dave-web-apps` |
| Region | `europe-west1` |
| Artifact Registry repository | `containers` |
| Image and Cloud Run service | `api-proxy` |
| Image tag | Application version plus commit, such as `1.0.0-<full-commit-SHA>` |
| Runtime service account | `api-proxy-run@PROJECT_ID.iam.gserviceaccount.com` |
| Secret Manager key | `google-maps-api-key`, version `1` |
| Container port | Cloud Run's `PORT`, normally `8080` |
| Workers / request concurrency | `2` / `2` |
| CPU / memory | `1` / `512Mi` |
| Minimum / maximum instances | `0` / `3` |

## Versioning

The application release version is defined once in
[`APIProxy/lib/APIProxy.pm`](APIProxy/lib/APIProxy.pm), starting at `1.0.0`.
Use stable [Semantic Versioning](https://semver.org/spec/v2.0.0.html): increment
MAJOR for incompatible API changes, MINOR for compatible features and PATCH for
compatible fixes. Update `$VERSION` in that file when preparing a release;
MakeMaker's package version and container tagging both read that value.

`bin/build_container` creates tags in the form `VERSION-TAG`, where `TAG` defaults
to the full Git commit SHA. For example, a `1.0.0` build is published as:

```text
europe-west1-docker.pkg.dev/dave-web-apps/containers/api-proxy:1.0.0-<full-commit-SHA>
```

The image also records the release version in its
`org.opencontainers.image.version` label. An explicit `TAG` supplies the suffix;
the script always obtains the version prefix from the application module. It
validates the stable `MAJOR.MINOR.PATCH` version and Docker tag before contacting
the registry. Reading the version needs Perl and ExtUtils::MakeMaker on the
build host, but does not load Dancer2 or the application dependencies.

Tags identify the release version and source commit. Cloud Run deployment and
rollback continue to use the resolved image digest, so an existing deployment
stays pinned even if a tag is rebuilt.

## Container behavior

`Dockerfile` installs the shared cpanfile and its `server` feature, then runs
Starman as a non-root user on `0.0.0.0:$PORT`. The `cloud_run` Dancer environment
has production error settings and console logging for Cloud Run's log collector.
It needs no writable application directory. The normal per-process memory cache
applies; it is not shared across workers or Cloud Run instances.

The build context excludes `.env`, GitHub's generated credentials and unrelated
repository files. `GOOGLE_MAPS_API_KEY` is injected at runtime from Secret Manager,
never baked into the image or supplied as a Docker build argument.

For a local smoke test, with no API key required:

```sh
docker build --platform linux/amd64 -t api-proxy:dev .
docker run --rm -p 8080:8080 api-proxy:dev
```

Visit `http://127.0.0.1:8080/`. Testing `/gmap_search` against Google requires a
valid key and is separate from the offline tests.

## Prepare Google Cloud once

Use the existing project and Artifact Registry repository from `feeds`, or
provision equivalents before the first build:

```sh
export PROJECT_ID=dave-web-apps
export REGION=europe-west1
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  secretmanager.googleapis.com --project "$PROJECT_ID"
gcloud artifacts repositories describe containers \
  --project "$PROJECT_ID" --location "$REGION"
```

If that repository does not exist, create it with `gcloud artifacts repositories
create containers --repository-format=docker --project "$PROJECT_ID" --location
"$REGION"`. Build scripts check for it and propagate permission errors rather
than attempting project provisioning on every run.

Create the runtime account and API-key secret if they do not already exist:

```sh
gcloud iam service-accounts create api-proxy-run --project "$PROJECT_ID"
gcloud secrets create google-maps-api-key --replication-policy=automatic \
  --project "$PROJECT_ID"
read -r -s -p 'Google Maps API key: ' GOOGLE_MAPS_KEY
printf '\n'
printf '%s' "$GOOGLE_MAPS_KEY" | gcloud secrets versions add google-maps-api-key \
  --data-file=- --project "$PROJECT_ID"
unset GOOGLE_MAPS_KEY
gcloud secrets add-iam-policy-binding google-maps-api-key \
  --project "$PROJECT_ID" \
  --member "serviceAccount:api-proxy-run@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/secretmanager.secretAccessor
```

Set the configured version to the number returned by `versions add`; it is `1`
for a new secret. The deployment deliberately uses a numeric version rather
than `latest`. To rotate the key, add another secret version, update the GitHub
variable below, and redeploy a known image digest. The runtime account needs
access to this secret, not project-wide editor privileges.

Use [Workload Identity Federation](https://github.com/google-github-actions/auth#workload-identity-federation)
for the GitHub deployer, as in `feeds`. The existing provider must admit
`davorg/api-proxy` on `refs/heads/main`, with `attribute.repository` mapped from
`assertion.repository`; preserve rules for other repositories when extending it.
Bind this repository's principal to the deployer service account with
`roles/iam.workloadIdentityUser`. A separate provider restricted to this
repository/main branch also works. No downloaded service-account key is needed.

The deployer needs:

- `roles/artifactregistry.writer` on the `containers` repository, including the
  metadata-read permissions used by the build script.
- `roles/run.admin` to deploy and allow public invocation of this proxy.
- `roles/iam.serviceAccountUser` on the runtime account.

For example, after setting `DEPLOYER_SERVICE_ACCOUNT` to the WIF deployer's email:

```sh
gcloud iam service-accounts add-iam-policy-binding \
  "api-proxy-run@${PROJECT_ID}.iam.gserviceaccount.com" --project "$PROJECT_ID" \
  --member "serviceAccount:${DEPLOYER_SERVICE_ACCOUNT}" \
  --role roles/iam.serviceAccountUser
```

The application does not implement request authentication or rate limiting;
the default deployment permits public invocation, matching its proxy role.
`ALLOW_UNAUTH=false` is available for deployments that require Cloud Run IAM.

## Configure GitHub Actions

Add these repository Actions secrets, using the same names as `feeds`:

| Secret | Value |
| --- | --- |
| `GCP_PROJECT_ID` | Google Cloud project ID |
| `GCP_WORKLOAD_ID_PROVIDER` | Full workload identity provider resource name |
| `GCP_SERVICE_ACCOUNT` | WIF deployer service-account email |

Optional repository Actions variables:

| Variable | Default |
| --- | --- |
| `GCP_REGION` | `europe-west1` |
| `GCP_AR_REPO` | `containers` |
| `CLOUD_RUN_SERVICE_ACCOUNT` | `api-proxy-run@PROJECT_ID.iam.gserviceaccount.com` |
| `GOOGLE_MAPS_API_KEY_SECRET` | `google-maps-api-key` |
| `GOOGLE_MAPS_API_KEY_SECRET_VERSION` | `1` |

Configure these before merging the deployment PR if the first `main` push should
deploy immediately. Without credentials, PR tests can still run; publication
and deployment cannot authenticate. Do not put the API-key payload in these
variables: the Cloud Run runtime identity reads it from Secret Manager.

`.github/workflows/build.yml` runs script tests, builds the Linux amd64 image,
runs offline application tests in the container, and checks startup as a non-root
user with a read-only filesystem on port `8081`. Pull requests stop there.
Successful `main` builds authenticate with WIF, publish the tested commit and
call `.github/workflows/deploy.yml` with only its digest. Passing the digest
avoids GitHub suppressing outputs containing a project ID stored as a secret.
Deployments run only from `main` and are serialized.

The deploy workflow also accepts a digest through manual dispatch for rollback.
Both scripts use explicit project/region flags and do not change the caller's
global gcloud project settings. Local use with an authenticated gcloud session:

```sh
PROJECT_ID=dave-web-apps REGION=europe-west1 bin/build_container
PROJECT_ID=dave-web-apps REGION=europe-west1 bin/deploy_container
```

The first script writes the immutable reference to `image_ref.txt`; the second
reads it or accepts `IMAGE_REF` and writes `service_url.txt`. Neither output is
tracked. Script overrides include `AR_REPO`, `IMAGE_NAME`, `TAG` (the suffix after
the application version) for builds, and
`SERVICE_NAME`, `RUNTIME_SERVICE_ACCOUNT`, the secret name/version, `WORKERS`,
`CONCURRENCY`, `MEMORY`, `MIN_INSTANCES`, `MAX_INSTANCES` and `ALLOW_UNAUTH` for
deployments. `CPU` is fixed to one. The request timeout is 60 seconds.

## Connect proxy.davecross.co.uk once

The existing `feeds.davecross.co.uk` service uses a native Cloud Run mapping in
`europe-west1`. The same mechanism is available here. Google currently labels
native mappings Preview and recommends a global external Application Load
Balancer for production; see the [custom-domain options and limitations](https://cloud.google.com/run/docs/mapping-custom-domains).
This setup follows the existing `feeds` mapping rather than provisioning a new
load balancer.

After the first successful service deployment, use an account with verified
ownership of `davecross.co.uk` to create the mapping:

```sh
gcloud beta run domain-mappings create --project "$PROJECT_ID" \
  --region "$REGION" --service api-proxy --domain proxy.davecross.co.uk
gcloud beta run domain-mappings describe --project "$PROJECT_ID" \
  --region "$REGION" --domain proxy.davecross.co.uk \
  --format='yaml(status.resourceRecords,status.conditions)'
```

Use the returned records to update the existing `proxy` DNS entry. For this
subdomain it is normally a CNAME to `ghs.googlehosted.com.`; use Google's actual
returned value. Replace the hostname's old origin target. If managing the
record in Cloudflare, use DNS-only mode during certificate provisioning.
Wait for the mapping's Ready condition before checking
`https://proxy.davecross.co.uk/`. Do not force-override a mapping for another
service. Domain ownership verification, DNS and certificate issuance are
one-time setup; subsequent digest deployments keep the mapping.

## Validate and roll back

```sh
prove -lv t/deployment_scripts.t
prove -IAPIProxy/lib -lr APIProxy/t
bash -n bin/build_container bin/deploy_container
```

The script tests use fake Docker/gcloud commands and never publish or deploy.
Container smoke tests exercise `/` without a real API key. Known query/response
defects remain tracked separately; successful deployment alone does not fix
them.

To roll back, dispatch the Deploy to Cloud Run workflow on `main` with a prior
`sha256:...` digest from this app's Artifact Registry image, or run:

```sh
IMAGE_REF="${REGION}-docker.pkg.dev/${PROJECT_ID}/containers/api-proxy@sha256:..." \
  bin/deploy_container
```

The deploy script rejects mutable tags, digests from another registry/image,
and nonnumeric secret versions before calling Google Cloud.
