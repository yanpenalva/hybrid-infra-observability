# Base image pinning and bump procedure

Every image this repository builds from or deploys is pinned as
`<repository>:<tag>@sha256:<digest>`. The digest is the registry's
multi-architecture index digest for that tag, so a pull resolves to the same
manifest list, on every architecture, in every environment.

| Reference | Pinned in |
| --- | --- |
| `debian:bookworm-slim` | `ansible/app/Dockerfile`, `ansible/db/Dockerfile`, `ansible/control-node/Dockerfile` |
| `busybox`, `prom/prometheus` | `k8s/monitoring/02-prometheus.yaml` |
| `grafana/grafana` | `k8s/monitoring/03-grafana.yaml` |
| `prom/alertmanager` | `k8s/monitoring/04-alertmanager.yaml` |

No other file carries an image reference; `ansible/docker-compose.yml` builds
the three local images and `scripts/route-check.sh` inspects the built
`hybrid-infra-observability-app:latest` tag.

## Resolve a digest

Three sources report the same value. Confirm the agreement before writing a
digest into a file.

With buildx:

```sh
docker buildx imagetools inspect debian:bookworm-slim
```

With crane:

```sh
crane digest grafana/grafana:11.6.0
```

Without a Docker daemon, through the registry HTTP API:

```sh
token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])')
curl -fsSL -D - -o /dev/null -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://registry-1.docker.io/v2/library/debian/manifests/bookworm-slim" \
  | grep -i '^docker-content-digest:'
```

The `Docker-Content-Digest` header equals the `Digest:` line that `imagetools`
prints, and the same value appears as the top-level `digest` field of
`https://hub.docker.com/v2/repositories/library/debian/tags/bookworm-slim`.
That response also lists the per-platform manifests, which is how the presence
of `linux/amd64` and `linux/arm64` is verified.

Re-resolving an unchanged tag must return the digest already in the file. A
different value means the tag was re-pushed and the pin is stale.

A digest that cannot be resolved is a hard stop: report the pin as blocked.
Never invent a digest, never copy one from another tag or repository, and never
hand-edit a single hex character to make a pull succeed.

## Bump order

1. Resolve the digest for the target tag and record the tag plus digest pair.
2. Update the three Dockerfiles first, in one step: `app`, `db` and
   `control-node` share one base image, and a partial update leaves the managed
   nodes and the controller on different bases.
3. Update the Kubernetes manifests: `busybox` and `prom/prometheus` in
   `02-prometheus.yaml`, Grafana in `03-grafana.yaml`, Alertmanager in
   `04-alertmanager.yaml`.
4. Run the static gates: `make verify` reports each stage, and
   `HIO_REQUIRE_TOOLS=1 make check` is the fail-closed variant. `kubeconform`
   validates the edited manifests and `hadolint` re-lints the edited
   Dockerfiles.
5. Run the runtime gates in `docs/demo.md` order: `make up`, `make monitoring`,
   `make smoke`, `make route-check`, then the drills. A base bump reaches
   production paths only after these pass on the target machine.
6. Commit the Dockerfiles and the manifests in one change per image family, so
   the recorded tag, the recorded digest and the running workloads stay aligned.

A tag and its digest describe the same manifest. Editing only the digest, or
pairing a digest with a different tag, makes the pull fail with
`manifest unknown`.

## Confirm what runs

Inside the cluster:

```sh
kubectl --context hybrid-infra-observability -n monitoring get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
kubectl --context hybrid-infra-observability -n monitoring get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].imageID}{"\n"}{end}'
```

Both lines must show the digest recorded in the manifest. For the images built
by Compose:

```sh
docker image inspect hybrid-infra-observability-app:latest --format '{{.RepoDigests}}'
HIO_METRICS_BIND=127.0.0.1 docker compose -f ansible/docker-compose.yml config --images
```

## What invalidates the pin

- **Tag re-push upstream.** The tag now points at another digest, so the tag in
  the reference and the digest no longer agree. Re-resolve and treat it as a
  bump.
- **Withdrawn or garbage-collected digest.** The pull fails with
  `manifest unknown` although the tag still exists in the registry listing.
- **Changed platform set.** A digest that no longer carries `linux/amd64` or
  `linux/arm64` fails on one of the architectures the lab builds and deploys on.
- **A tag that hides a base change.** `bookworm-slim` is a stable tag; the bytes
  behind it are not. Only the digest records which point release was reviewed.
- **A rebuild outside the pin.** `docker build` against an unpinned reference, or
  an image built before the pin landed, resolves to whatever the tag returned at
  that moment.

## Dependabot

`.github/dependabot.yml` opens weekly grouped updates for GitHub Actions, and a
single grouped Docker update that covers the three Dockerfile directories. A
Docker update therefore raises the tag or the digest of `app`, `db` and
`control-node` in one pull request, which applies step 2 of the bump order as a
single change: keep the Kubernetes manifests consistent and run the gates before
merging. The Kubernetes images have no Dependabot coverage and are re-checked
with the commands above.
