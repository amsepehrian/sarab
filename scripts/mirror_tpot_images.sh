#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/compose/tpot_services.yml}"
SOURCE_REPO="${SOURCE_REPO:-}"
SOURCE_VERSION="${SOURCE_VERSION:-}"
LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5000}"
LOCAL_NAMESPACE="${LOCAL_NAMESPACE:-telekom-security}"
TARGET_VERSION="${TARGET_VERSION:-}"
START_REGISTRY="${START_REGISTRY:-1}"
PUSH_BASE_IMAGES="${PUSH_BASE_IMAGES:-0}"
UPDATE_ENV="${UPDATE_ENV:-0}"
DRY_RUN="${DRY_RUN:-0}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Mirror all images referenced by compose/tpot_services.yml into a local registry.

Options:
  --env-file PATH          Env file to read/update (default: .env)
  --compose-file PATH      Compose file to scan (default: compose/tpot_services.yml)
  --source-repo REPO       Source image repo (default: TPOT_REPO from env file)
  --source-version TAG     Source image tag (default: TPOT_VERSION from env file)
  --local-registry HOST    Local registry host (default: localhost:5000)
  --local-namespace NAME   Namespace in local registry (default: telekom-security)
  --target-version TAG     Target tag (default: source version)
  --no-start-registry      Do not start compose/local_registry.yml
  --push-base-images       Also mirror Dockerfile FROM base images
  --update-env             Update .env TPOT_REPO to local registry namespace
  --dry-run                Print planned mirror operations without docker changes
  -h, --help               Show this help

Examples:
  scripts/mirror_tpot_images.sh
  scripts/mirror_tpot_images.sh --update-env
  LOCAL_REGISTRY=192.168.1.10:5000 scripts/mirror_tpot_images.sh --update-env
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --compose-file) COMPOSE_FILE="$2"; shift 2 ;;
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    --source-version) SOURCE_VERSION="$2"; shift 2 ;;
    --local-registry) LOCAL_REGISTRY="$2"; shift 2 ;;
    --local-namespace) LOCAL_NAMESPACE="$2"; shift 2 ;;
    --target-version) TARGET_VERSION="$2"; shift 2 ;;
    --no-start-registry) START_REGISTRY=0; shift ;;
    --push-base-images) PUSH_BASE_IMAGES=1; shift ;;
    --update-env) UPDATE_ENV=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

read_env_value() {
  local key="$1"
  if [[ -f "$ENV_FILE" ]]; then
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
  fi
}

write_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

extract_tpot_images() {
  local image
  while IFS= read -r image; do
    image="${image//\"/}"
    image="${image//\$\{TPOT_REPO\}/$SOURCE_REPO}"
    image="${image//\$\{TPOT_VERSION\}/$SOURCE_VERSION}"
    printf '%s\n' "$image"
  done < <(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$COMPOSE_FILE") | sort -u
}

extract_base_images() {
  find "$ROOT_DIR/docker" -name Dockerfile -type f -print0 \
    | xargs -0 sed -nE 's/^[[:space:]]*FROM([[:space:]]+--[^[:space:]]+)*[[:space:]]+([^[:space:]]+).*/\2/p' \
    | grep -v '^scratch$' \
    | grep -v '[$]' \
    | sort -u
}

mirror_image() {
  local source_image="$1"
  local target_image="$2"

  echo "==> ${source_image} -> ${target_image}"
  if [[ "$DRY_RUN" == "1" ]]; then
    return
  fi
  docker pull "$source_image"
  docker tag "$source_image" "$target_image"
  docker push "$target_image"
}

require_cmd sed
require_cmd sort

if [[ "$DRY_RUN" != "1" ]]; then
  require_cmd docker
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi

SOURCE_REPO="${SOURCE_REPO:-$(read_env_value TPOT_REPO)}"
SOURCE_VERSION="${SOURCE_VERSION:-$(read_env_value TPOT_VERSION)}"
TARGET_VERSION="${TARGET_VERSION:-$SOURCE_VERSION}"

if [[ -z "$SOURCE_REPO" || -z "$SOURCE_VERSION" ]]; then
  echo "SOURCE_REPO/TPOT_REPO and SOURCE_VERSION/TPOT_VERSION are required." >&2
  exit 1
fi

LOCAL_REPO="${LOCAL_REGISTRY%/}/${LOCAL_NAMESPACE}"

if [[ "$START_REGISTRY" == "1" && "$DRY_RUN" != "1" ]]; then
  docker compose -f "$ROOT_DIR/compose/local_registry.yml" up -d
fi

while IFS= read -r source_image; do
  [[ -n "$source_image" ]] || continue
  image_name="${source_image##*/}"
  image_name="${image_name%%:*}"
  mirror_image "$source_image" "${LOCAL_REPO}/${image_name}:${TARGET_VERSION}"
done < <(extract_tpot_images)

if [[ "$PUSH_BASE_IMAGES" == "1" ]]; then
  while IFS= read -r source_image; do
    [[ -n "$source_image" ]] || continue
    safe_name="${source_image%%:*}"
    safe_name="${safe_name//\//-}"
    tag="${source_image##*:}"
    [[ "$tag" == "$source_image" ]] && tag="latest"
    mirror_image "$source_image" "${LOCAL_REGISTRY%/}/base/${safe_name}:${tag}"
  done < <(extract_base_images)
fi

if [[ "$UPDATE_ENV" == "1" && "$DRY_RUN" != "1" ]]; then
  write_env_value TPOT_REPO "$LOCAL_REPO"
  write_env_value TPOT_VERSION "$TARGET_VERSION"
  echo "Updated ${ENV_FILE}: TPOT_REPO=${LOCAL_REPO}, TPOT_VERSION=${TARGET_VERSION}"
fi

echo "Done. Use TPOT_REPO=${LOCAL_REPO} and TPOT_VERSION=${TARGET_VERSION}."
