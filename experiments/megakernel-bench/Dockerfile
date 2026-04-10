# syntax=docker/dockerfile:1.7
# Luce Megakernel — Benchmark Image
#
# Base: nvidia/cuda 12.4.1 devel on Ubuntu 22.04
#   - Provides nvcc, CUDA headers, cuBLAS, cuDNN build files
#   - Compatible with sm_89 (Ada: RTX 4000 Ada, RTX 4090)
#   - For Blackwell (sm_120: RTX 5070 Ti, 5090), bump to 12.8-devel-ubuntu24.04
#     and set TORCH_CUDA_ARCH_LIST="12.0+PTX" at build time.
#
# This image intentionally does NOT bake in the Luce megakernel source.
# The benchmark Job clones the repo at runtime into a mounted PVC so you
# can iterate on kernel code without rebuilding the image.
#
# Build:
#   docker buildx build \
#     --platform linux/amd64 \
#     -t ghcr.io/vespo92/megakernel-bench:cuda12.4-torch2.5 \
#     --push .
#
# The :cuda12.4-torch2.5 tag pins both CUDA toolkit and PyTorch ABI so
# results from different runs are comparable.

ARG CUDA_VERSION=12.4.1
ARG UBUNTU_VERSION=22.04
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    # All caches under /workspace so a single PVC persists everything
    HF_HOME=/workspace/.cache/huggingface \
    HUGGINGFACE_HUB_CACHE=/workspace/.cache/huggingface/hub \
    TORCH_HOME=/workspace/.cache/torch \
    XDG_CACHE_HOME=/workspace/.cache \
    # Ada target by default; override at runtime for Blackwell/Hopper
    TORCH_CUDA_ARCH_LIST="8.9" \
    # CUDA toolkit paths (already set by nvidia/cuda base but explicit)
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64

# System dependencies for building PyTorch C++ extensions and CUDA kernels
RUN apt-get update && apt-get install -y --no-install-recommends \
        # Python
        python3 python3-pip python3-dev python3-venv \
        # Build toolchain (nvcc needs a host compiler)
        build-essential ninja-build cmake pkg-config \
        # Source control + fetching
        git git-lfs curl ca-certificates \
        # Profiling + debug
        numactl libnuma-dev htop procps lsof strace \
        # HuggingFace / safetensors helpers
        zstd xz-utils \
        # NVIDIA persistence daemon client (optional but useful)
        kmod \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && ln -sf /usr/bin/pip3    /usr/local/bin/pip

# PyTorch matching CUDA 12.4 (cu124 wheels)
# Pinning exact version so benchmark runs are reproducible across rebuilds.
ARG TORCH_VERSION=2.5.1
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu124
RUN pip install --upgrade pip setuptools wheel \
 && pip install \
        torch==${TORCH_VERSION} \
        --index-url ${TORCH_INDEX}

# Python libraries the megakernel + benchmark harness need
RUN pip install \
        numpy \
        einops \
        transformers \
        safetensors \
        huggingface_hub \
        tqdm \
        pynvml \
        ninja

# Workspace directory — mounted over by a PVC in k8s
WORKDIR /workspace
RUN mkdir -p /workspace /workspace/.cache /workspace/results

# Non-interactive default. The Job manifest overrides command/args.
# Running as root because CUDA + container device access is simpler that way
# and this is a single-tenant research workload.
CMD ["/bin/bash", "-lc", "nvidia-smi && python -c 'import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else None)' && exec bash"]
