# ============================================================
# Voicebox — Local TTS Server with Web UI
# 3-stage build: Frontend → Python deps → Runtime
#
# Build variants:
#   CPU (default):  docker compose up --build
#   ROCm (AMD GPU): docker compose -f docker-compose.yml -f docker-compose.rocm.yml up --build
# ============================================================

# Top-level ARG so it is visible to all stages.
ARG PYTORCH_VARIANT=cpu

# === Stage 1: Build frontend ===
# Registries are fully qualified so the build works under Podman, which does not
# resolve Docker's implicit docker.io short names.
FROM docker.io/oven/bun:1 AS frontend

WORKDIR /build

# Copy workspace config and frontend source
COPY package.json bun.lock CHANGELOG.md ./
COPY app/ ./app/
COPY web/ ./web/

# Strip workspaces not needed for web build, and fix trailing comma
RUN sed -i '/"tauri"/d; /"landing"/d' package.json && \
    sed -i -z 's/,\n  ]/\n  ]/' package.json
RUN bun install --no-save
# Build frontend (skip tsc — upstream has pre-existing type errors)
RUN cd web && bunx --bun vite build


# === Stage 2: Build Python dependencies ===
FROM docker.io/library/python:3.11-slim AS backend-builder

# Re-declare ARG inside the stage (Docker scoping requirement).
ARG PYTORCH_VARIANT=cpu

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip

COPY backend/requirements.txt .

# Every pip step below installs with --prefix=/install, which pip does NOT add to
# sys.path — so each invocation is blind to what the previous one installed and
# happily re-resolves torch. Overlapping files then land in the same tree and the
# last writer wins, which can leave a mixed install (e.g. a 2.13.0 torch package
# shadowing a pinned 2.6.0 one, with both .dist-info directories present).
#
# A constraints file is the cheap fix: it is empty by default (no behaviour
# change) and the GPU branches below fill it in, so every later step is pinned to
# the same torch they selected.
ENV PIP_CONSTRAINT=/tmp/pip-constraints.txt
RUN touch /tmp/pip-constraints.txt

# ROCm wheel index. Default 6.3 (RDNA1/2/3); set ROCM_VERSION=7.2 for RDNA4.
ARG ROCM_VERSION=6.3

# For ROCm, make the PyTorch ROCm index primary so every install below resolves
# torch to ROCm wheels instead of the default CUDA build.
RUN if [ "$PYTORCH_VARIANT" = "rocm" ]; then \
      pip install --no-cache-dir --prefix=/install \
        --index-url "https://download.pytorch.org/whl/rocm${ROCM_VERSION}" \
        torch torchaudio && \
      printf '[global]\nindex-url = https://download.pytorch.org/whl/rocm%s\nextra-index-url = https://pypi.org/simple\n' "$ROCM_VERSION" > /etc/pip.conf; \
    fi

# CUDA wheel index, for GPUs the current default PyPI torch no longer supports.
# Recent wheels have dropped older architectures — torch 2.13/cu130 starts at
# sm_75 (Turing), so Pascal (GTX 10xx, sm_61) and Maxwell get
# "no kernel image is available for execution on the device" at the first kernel
# launch, even though torch.cuda.is_available() reports True.
#
# cu124 / torch 2.6.0 ships sm_50-sm_90 and is verified working on a GTX 1080.
# Newer cards do not need this variant; the default build already covers them.
ARG CUDA_VERSION=124
ARG TORCH_VERSION=2.6.0

# Pin torch first and make the CUDA index primary, so the requirements install
# below keeps this build instead of resolving a newer one from PyPI.
RUN if [ "$PYTORCH_VARIANT" = "cuda" ]; then \
      pip install --no-cache-dir --prefix=/install \
        --index-url "https://download.pytorch.org/whl/cu${CUDA_VERSION}" \
        "torch==${TORCH_VERSION}" torchaudio && \
      printf '[global]\nindex-url = https://download.pytorch.org/whl/cu%s\nextra-index-url = https://pypi.org/simple\n' "$CUDA_VERSION" > /etc/pip.conf && \
      printf 'torch==%s+cu%s\ntorchaudio==%s+cu%s\n' \
        "$TORCH_VERSION" "$CUDA_VERSION" "$TORCH_VERSION" "$CUDA_VERSION" \
        > /tmp/pip-constraints.txt; \
    fi

# CPU wheel index. Without this the "cpu" variant is not actually CPU-only: no
# branch above matches, torch resolves from default PyPI, and that wheel bundles
# ~2.7GB of nvidia/* CUDA libraries the container can never use. Worse, the
# current default is 2.13/cu130 — precisely the sm_75+ build the CUDA section
# above exists to avoid — so the "cpu" image was silently the most dangerous one
# to point a Pascal host at. Measured before this fix: PYTORCH_VARIANT=cpu
# produced a 7.64GB image carrying torch 2.13.0+cu130 and a full nvidia/ tree.
#
# Making the CPU index primary also keeps the requirements install below on CPU
# wheels, the same way the rocm and cuda branches do.
RUN if [ "$PYTORCH_VARIANT" = "cpu" ]; then \
      pip install --no-cache-dir --prefix=/install \
        --index-url "https://download.pytorch.org/whl/cpu" \
        torch torchaudio && \
      printf '[global]\nindex-url = https://download.pytorch.org/whl/cpu\nextra-index-url = https://pypi.org/simple\n' > /etc/pip.conf; \
    fi

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# k2, for LuxTTS. Without it LuxTTS logs "Failed import k2 ... Swoosh functions
# will fallback to PyTorch implementation, leading to slower speed and higher
# memory consumption" — and that fallback is heavy enough to OOM a small host.
#
# k2 wheels are built against an exact (CUDA, torch, cpython) triple, so this is
# pinned to the same CUDA_VERSION/TORCH_VERSION selected above and only installs
# for the cuda variant. If you change either ARG, pick the matching wheel from
# https://k2-fsa.github.io/k2/cuda.html or this install will fail.
ARG K2_VERSION=1.24.4.dev20260625
RUN if [ "$PYTORCH_VARIANT" = "cuda" ]; then \
      pip install --no-cache-dir --prefix=/install --no-deps \
        --find-links https://k2-fsa.github.io/k2/cuda.html \
        "k2==${K2_VERSION}+cuda12.4.torch${TORCH_VERSION}"; \
    fi

RUN pip install --no-cache-dir --prefix=/install --no-deps chatterbox-tts
RUN pip install --no-cache-dir --prefix=/install --no-deps hume-tada
RUN pip install --no-cache-dir --prefix=/install \
    git+https://github.com/QwenLM/Qwen3-TTS.git


# === Stage 3: Runtime ===
FROM docker.io/library/python:3.11-slim

# Create non-root user; the entrypoint joins GPU device groups at runtime.
# The home directory is chowned explicitly because useradd left it root-owned and
# 0700 here, so uid 999 could not traverse its own home. Everything beneath then
# became unreadable to the app — including a model-cache volume mounted at
# ~/.cache/huggingface — and the server died at import in hf_offline_patch with
# "Permission denied", which reads like a corrupt cache rather than a directory
# mode. Do not rely on useradd's default.
RUN groupadd -r voicebox && \
    useradd -r -g voicebox -m -s /bin/bash voicebox && \
    chown voicebox:voicebox /home/voicebox && \
    chmod 755 /home/voicebox

WORKDIR /app

# Install only runtime system dependencies (gosu drops root in the entrypoint)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from builder stage
COPY --from=backend-builder /install /usr/local

# Copy backend application code
COPY --chown=voicebox:voicebox backend/ /app/backend/

# Copy built frontend from frontend stage
COPY --from=frontend --chown=voicebox:voicebox /build/web/dist /app/frontend/

# Create data directories owned by non-root user
RUN mkdir -p /app/data/generations /app/data/profiles /app/data/cache \
    && chown -R voicebox:voicebox /app/data

# Expose the API port
EXPOSE 17493

# Health check — auto-restart if the server hangs
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
    CMD curl -f http://localhost:17493/health || exit 1

# Entrypoint joins GPU groups then drops to the voicebox user
COPY --chmod=755 scripts/rocm-entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "17493"]
