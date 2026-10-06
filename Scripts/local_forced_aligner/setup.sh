#!/bin/bash
set -euo pipefail

APP_SUPPORT="${HOME}/Library/Application Support/MaGiKara/LocalForcedAligner"
PYTHON_BIN="${APP_SUPPORT}/venv/bin/python"
MODEL_DIR="${APP_SUPPORT}/models/yohane-ja-latn"
MODEL_REVISION="2ab2b5f46539ee284703c281f286b01d2410ee12"
MODEL_BYTES="1261938632"
MODEL_SHA256="4d1d6fbb543534ab32bcceac5f5a42052c7fde3d16a83cbbce858473d5735042"

echo "Yohane model card license: CC BY-NC-SA 4.0 (non-commercial; share-alike)."
echo "Weights are about 1.26 GB and this setup is only for local, non-commercial evaluation."
read -r -p "If that is acceptable, type LOCAL-ONLY to continue: " LICENSE_ACK
if [[ "${LICENSE_ACK}" != "LOCAL-ONLY" ]]; then
  echo "Stopped without downloading the model." >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "需要先安装 uv，并确保 python3.12 可用。" >&2
  exit 1
fi

uv venv --python 3.12 "${APP_SUPPORT}/venv"
uv pip install --python "${PYTHON_BIN}" \
  'torch==2.8.0' \
  'torchaudio==2.8.0' \
  'transformers==4.57.3' \
  'pykakasi==2.3.0' \
  'soundfile>=0.13.1' \
  'huggingface_hub>=0.34,<1.0'

HF_XET_HIGH_PERFORMANCE=1 "${PYTHON_BIN}" -c 'from huggingface_hub import snapshot_download; print(snapshot_download(repo_id="NextFire/mms-300m-ForcedAligner-karaoke-ja-Latn", local_dir="'"${MODEL_DIR}"'", revision="'"${MODEL_REVISION}"'"))'

ACTUAL_BYTES="$(stat -f '%z' "${MODEL_DIR}/model.safetensors")"
if [[ "${ACTUAL_BYTES}" != "${MODEL_BYTES}" ]]; then
  echo "模型大小不符：expected=${MODEL_BYTES}, actual=${ACTUAL_BYTES}" >&2
  exit 1
fi
ACTUAL_SHA256="$(shasum -a 256 "${MODEL_DIR}/model.safetensors" | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${MODEL_SHA256}" ]]; then
  echo "模型 SHA-256 校验失败：${ACTUAL_SHA256}" >&2
  exit 1
fi

echo "本机实验环境已就绪：${APP_SUPPORT}"
