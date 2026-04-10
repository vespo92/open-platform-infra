# Luce Megakernel — Benchmark & Port Experiment

Research experiment to port the [Luce Megakernel](https://github.com/Luce-Org/luce-megakernel)
from its original RTX 3090 target to other NVIDIA consumer GPUs, starting with
the **RTX 4000 Ada 20GB** (sm_89) and later the **RTX 5070 Ti** (sm_120).

The upstream megakernel fuses all 24 layers of Qwen 3.5-0.8B (hybrid
DeltaNet + Attention) into a single persistent CUDA kernel, eliminating
per-token kernel-launch overhead between layers. On a 3090 at 220W it hits
**1.87 tok/J** — matching Apple Silicon on efficiency while delivering 1.8x
the throughput on a $700 used GPU.

This repo runs that benchmark against our hardware, measures the delta,
and uses the result to validate the "megakernel per GPU" multi-model
parallelism architecture on the open-platform cluster.

## Status

| Phase | Target | State |
|-------|--------|-------|
| 1 | RTX 4000 Ada — verify build, parameterize SM count | scaffolded, untested |
| 2 | RTX 4000 Ada — tune `S_TILE`, reach stable baseline tok/J | not started |
| 3 | RTX 5070 Ti — CUDA 12.8 image, sm_120 compile | not started |
| 4 | Multi-GPU multi-model parallelism via K8s scheduling | not started |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  open-platform-infra / NixOS host                           │
│  ├── hardware.nvidia (proprietary driver, stable channel)  │
│  ├── hardware.nvidia-container-toolkit (CDI specs)         │
│  └── k3s containerd (CDI enabled)                          │
│                                                             │
│  ├── nvidia-device-plugin (kube-system DaemonSet)          │
│  │     advertises nvidia.com/gpu                           │
│  │                                                         │
│  └── megakernel-bench namespace                             │
│      ├── PVC megakernel-workspace (source + weights cache)  │
│      ├── ConfigMap megakernel-runner (bench.sh + dev.sh)    │
│      ├── Job megakernel-bench (one-shot final_bench.py)     │
│      └── Deployment megakernel-dev (replicas=0, scale up   │
│                                    for interactive work)   │
└─────────────────────────────────────────────────────────────┘
```

**Why this split**: the benchmark Job is one-shot and produces publishable
numbers. The dev Deployment holds the same PVC so you can exec in, edit
`kernel.cu`, rebuild, re-run — all without re-scheduling a cold Job. Scale
it to 0 when you're done so the GPU goes back to the pool.

## Prerequisites (bundled in this branch)

These are additions in `feat/megakernel-bench` that the experiment depends on:

1. **`modules/gpu-nvidia.nix`** — NixOS module that installs the NVIDIA
   proprietary driver + `nvidia-container-toolkit` whenever `enableGpu = true`
   in `node-config.nix`. Imported from `hosts/worker/configuration.nix`.
2. **`infrastructure/nvidia-device-plugin/`** — DaemonSet that advertises
   `nvidia.com/gpu` to the scheduler, plus a `RuntimeClass nvidia` for
   workloads that want to be explicit about GPU routing. Wired into the
   top-level infrastructure kustomization.

Apply both before running the experiment:

```bash
# On the GPU node:
sudo nixos-rebuild switch --no-flake   # picks up gpu-nvidia.nix
sudo reboot                             # driver kmod loads clean

# From your workstation, against the cluster:
kubectl apply -k infrastructure/   # picks up the device plugin
```

Verify:

```bash
# Host
nvidia-smi
nvidia-ctk --version

# Cluster
kubectl -n kube-system get ds nvidia-device-plugin
kubectl describe node <gpu-node> | grep nvidia.com/gpu
# Expected: `nvidia.com/gpu: 1` under Allocatable
```

## Build the benchmark image

The benchmark image bundles CUDA 12.4 + PyTorch 2.5.1 (cu124 wheels) +
build toolchain. It deliberately does **not** bake in the Luce source —
the Job clones it at runtime so you can iterate on kernel code via the
dev pod without rebuilding the image.

```bash
cd experiments/megakernel-bench
docker buildx build \
  --platform linux/amd64 \
  -t ghcr.io/vespo92/megakernel-bench:cuda12.4-torch2.5 \
  --push \
  .
```

Then update the image reference in `k8s/job-benchmark.yaml` and
`k8s/deployment-dev.yaml` if you push to a different registry.

### For the RTX 5070 Ti (Phase 3)

Bump the base and PyTorch:

```dockerfile
FROM nvidia/cuda:12.8.0-devel-ubuntu24.04
# TORCH_VERSION=2.6.0  (or nightly)
# TORCH_INDEX=https://download.pytorch.org/whl/cu128
# TORCH_CUDA_ARCH_LIST="12.0+PTX"
```

Tag as `:cuda12.8-torch2.6` and run the same benchmark Job with that image.

## Run the benchmark

```bash
kubectl apply -k experiments/megakernel-bench/k8s/
kubectl -n megakernel-bench logs -f job/megakernel-bench
```

The Job will:

1. Print GPU facts (`nvidia-smi`, SM count, compute capability, bandwidth)
2. Print PyTorch + CUDA visibility
3. Clone `Luce-Org/luce-megakernel` into `/workspace/luce-megakernel`
4. `pip install -e .` (compiles `kernel.cu` + `prefill.cu` via PyTorch's
   CUDA extension builder — this is the first place something can fail)
5. Write a metadata JSON to `/workspace/results/<run-id>-meta.json`
6. Run `python final_bench.py` (10 warmup + 20 timed runs averaged per the
   paper's methodology) and tee output to `/workspace/results/<run-id>-bench.log`

### Expected first-run failure (this is good)

The upstream kernel hardcodes **82 blocks** because the RTX 3090 has 82 SMs.
The RTX 4000 Ada has **48 SMs**. Cooperative grid launches require all blocks
to be resident simultaneously, so `cudaLaunchCooperativeKernel` will reject
the launch with something like:

```
CUDA error: too many blocks in cooperative launch
```

**This is the expected Phase 1 wall.** It means the build succeeded, the
kernel loaded, and we reached the launch. Next step is to parameterize the
block count.

## Iterate via the dev pod

```bash
# Scale up (takes the GPU reservation)
kubectl -n megakernel-bench scale deploy/megakernel-dev --replicas=1
kubectl -n megakernel-bench rollout status deploy/megakernel-dev

# Exec in
kubectl -n megakernel-bench exec -it deploy/megakernel-dev -- bash

# Inside the pod:
cd /workspace/luce-megakernel
nvidia-smi
python -c "import torch; p=torch.cuda.get_device_properties(0); print(p.name, p.multi_processor_count, 'SMs')"

# Find the hardcoded 82 and parameterize:
grep -n '82' kernel.cu torch_bindings.cpp model.py

# After edits:
pip install -e . --no-deps
python bench_pp_tg.py   # quick single-run sanity + correctness check
python final_bench.py   # full warmed benchmark

# When done, scale back to free the GPU
exit
kubectl -n megakernel-bench scale deploy/megakernel-dev --replicas=0
```

## Interpreting results

`final_bench.py` reports tokens/second for prefill (pp520) and decode
(tg128). The paper's numbers on a 3090 stock 420W:

| Metric | Value |
|--------|-------|
| Prefill (pp520) | 37,800 tok/s |
| Decode  (tg128) | 413 tok/s |
| Draw (220W limit) | 220 W |
| tok/J | 1.87 |

### What to expect on the RTX 4000 Ada 20GB

The 4000 Ada is bandwidth-limited vs the 3090:

| | RTX 3090 | RTX 4000 Ada 20GB |
|---|---|---|
| SM count | 82 | 48 |
| Memory bandwidth | 936 GB/s | ~280–360 GB/s |
| Native TDP | 350 W | 130 W |

Decode is memory-bound, so **do not expect 3090 throughput**. The interesting
number is **tok/J** at the card's native 130W — the 3090 had to be
power-limited to 220W to reach 1.87 tok/J; the 4000 Ada is natively in
that zone. If the port lands cleanly, expect something in the
**~150–200 tok/s decode / 1.1–1.6 tok/J** range.

The point of the experiment is not "did we beat the 3090" (we won't —
different card, different bandwidth). The point is **"does the
megakernel approach generalize across NVIDIA architectures, and does
it land the efficiency win on a natively-efficient card."**

### Scientific rigor

- Always use `final_bench.py`, never `bench_pp_tg.py`, for published
  numbers. `bench_pp_tg.py` is the correctness-checking quick path and
  under-reports prefill because it isn't warmed.
- Run at least three separate Job invocations and report the median.
  Thermal state carries across runs if the card doesn't cool between them.
- Capture nvidia-smi continuously during the benchmark with
  `nvidia-smi dmon -s pucvmet -i 0` in a second kubectl exec session if
  you want a power trace.
- Power numbers should come from NVML (`pynvml.nvmlDeviceGetPowerUsage`),
  matching the paper's methodology. Don't trust wall-socket measurements
  for tok/J comparisons unless you also measure the 3090 the same way.

### DVFS sweep (Phase 2)

```bash
# Inside the dev pod, as root (pod runs as root):
nvidia-smi -pl 130   # native
python final_bench.py
nvidia-smi -pl 100   # aggressive
python final_bench.py
nvidia-smi -pl 80    # probably starved
python final_bench.py
```

Plot tok/s and tok/J vs power limit. The 3090's curve was nonlinear with
a sweet spot — the 4000 Ada's curve will tell us whether natively-efficient
cards have the same shape or already sit at the knee.

## Multi-model parallelism (Phase 4)

Once Phase 1–3 are solid and both cards have working megakernel builds,
the per-GPU persistent-kernel pattern unlocks a new serving topology:

```
GPU 0 (RTX 4000 Ada)  → megakernel process → Model A
GPU 1 (RTX 5070 Ti)   → megakernel process → Model B
CPU (mostly idle)     → LiteLLM router in front of both
```

Because a megakernel pins the CPU at near-zero during token generation,
N of them on one box is trivially scalable — K8s just schedules one pod
per GPU with different model weights. Asymmetric GPUs are fine because
there's no tensor-parallel sync between them.

We already have the control plane for this in `services/litellm/` —
add two custom backends pointing at the two megakernel Deployments and
LiteLLM will route between them as a unified OpenAI-compatible endpoint.

See the `LESSONS-LEARNED.md` update (Phase 4) for implementation details
once we get there.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | CUDA 12.4 + PyTorch 2.5.1 + build toolchain. No source baked in. |
| `k8s/namespace.yaml` | Experiment namespace |
| `k8s/pvc.yaml` | Workspace PVC (source + HF cache + results) |
| `k8s/configmap-runner.yaml` | `bench.sh` + `dev.sh` — edit without image rebuild |
| `k8s/job-benchmark.yaml` | One-shot benchmark Job |
| `k8s/deployment-dev.yaml` | Long-lived dev pod, replicas=0 by default |
| `k8s/kustomization.yaml` | Wires it all together |

## Cleanup

```bash
kubectl delete -k experiments/megakernel-bench/k8s/
# The PVC is not deleted automatically — keep it to preserve results,
# or delete explicitly:
kubectl -n megakernel-bench delete pvc megakernel-workspace
```

## References

- [Luce Megakernel repo](https://github.com/Luce-Org/luce-megakernel)
- [Luce blog post](https://lucebox.com/blog/megakernel)
- [Hazy Research: No Bubbles (megakernel origin work)](https://hazyresearch.stanford.edu/blog/2025-05-27-no-bubbles)
- [Luce `RESULTS.md` — full DVFS sweep on 3090](https://github.com/Luce-Org/luce-megakernel/blob/main/RESULTS.md)
