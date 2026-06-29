# Local Docker Registry

This project already references service images through `.env` variables:

- `TPOT_REPO`
- `TPOT_VERSION`

Use `scripts/mirror_tpot_images.sh` to pull every image referenced by `compose/tpot_services.yml`, retag it into a local registry, and push it there.

## Start the Registry

```bash
docker compose -f compose/local_registry.yml up -d
```

The registry listens on `127.0.0.1:5000` by default and stores data under `./data/local_registry`.

To expose it to other hosts:

```bash
LOCAL_REGISTRY_BIND=0.0.0.0:5000 docker compose -f compose/local_registry.yml up -d
```

## Mirror T-Pot Images

```bash
scripts/mirror_tpot_images.sh
```

This mirrors all unique `${TPOT_REPO}/name:${TPOT_VERSION}` images from `compose/tpot_services.yml` to:

```text
localhost:5000/telekom-security/name:${TPOT_VERSION}
```

To update `.env` automatically after mirroring:

```bash
scripts/mirror_tpot_images.sh --update-env
```

For a registry reachable by other machines:

```bash
LOCAL_REGISTRY=192.168.1.10:5000 scripts/mirror_tpot_images.sh --update-env
```

## Mirror Dockerfile Base Images Too

Service runtime images are enough for normal `docker compose up`. If you also want images used by `FROM` in `docker/**/Dockerfile` for local builds:

```bash
scripts/mirror_tpot_images.sh --push-base-images
```

Base images are pushed under `localhost:5000/base/...`.

## Use the Local Registry

If you did not use `--update-env`, edit `.env` manually:

```env
TPOT_REPO=localhost:5000/telekom-security
TPOT_VERSION=24.04.1
```

Then run T-Pot as usual with your compose file.

## Notes

- Docker treats `localhost:5000` as an insecure local registry automatically.
- For non-local IPs or hostnames using plain HTTP, configure Docker `insecure-registries` on each client.
- `compose/local_registry.yml` uses the official `registry:2` image, so the first start still needs access to that image unless it already exists locally.
