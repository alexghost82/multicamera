# ACTA Phase 3 — Local Qwen + vLLM Metal Hardware Benchmark & Integration Evidence

Date: 2026-11-20  
Target Host: Apple Silicon Mac (`Apple M5`, 24 GB Unified Memory / `25,769,803,776` bytes, `macOS 27.2.1` `26B131`, Swift `6.4.2`)  
Upstream Engine: `https://github.com/vllm-project/vllm-metal` (Homebrew `/opt/homebrew/Cellar/vllm-metal/0.30.0`, `/opt/homebrew/bin/vllm`, plugin `metal -> vllm_metal:register`)  
Exact Checkpoint Tested: `/Users/alexandr.bogdanov/Documents/multicamera/native/.build/models/qwen3.5-9b`

---

## 1. Checkpoint & Runtime Configuration

- **Architecture:** `Qwen3_5ForConditionalGeneration` (`model_type: "qwen3_5"`, hybrid `linear_attention` + `full_attention` every 4th layer, multimodal vision with `image_token_id: 248056`)
- **Quantization:** 4-bit affine (`bits: 4`, `group_size: 64`, 5.6 GB on disk)
- **Offline & Local-Only Flags:** `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, `VLLM_MLX_DEVICE=gpu`, `VLLM_METAL_MULTIMODAL_MODE=auto`
- **Spike Launch Command:**
  ```sh
  /opt/homebrew/bin/vllm serve /Users/alexandr.bogdanov/Documents/multicamera/native/.build/models/qwen3.5-9b \
    --host 127.0.0.1 --port 18735 \
    --served-model-name qwen3.5-9b \
    --api-key <EPHEMERAL_PER_LAUNCH_TOKEN> \
    --max-model-len 8192 --max-num-seqs 4 \
    --enable-auto-tool-choice --tool-call-parser qwen3_coder
  ```
- **Observed Engine Features (from server log):**
  - `NAX prefill attention kernels loaded (M5 tensor units)`
  - `Native paged-attention Metal kernels loaded`
  - `Metal: chunked prefill enabled (paged attention), max_num_batched_tokens=2048`
  - `Hybrid shared cache: 617 blocks, 9.94 GiB backing for KV and state` (spike default `--gpu-memory-utilization=0.92`; ACTA managed default uses conservative `--gpu-memory-utilization 0.65` to preserve headroom for live CoreML/ONNX camera pipelines).

---

## 2. Functional Gate Verification (Stage 3A — Live Hardware)

| Gate | Result | Measured Evidence |
| :--- | :--- | :--- |
| **Cold startup + multimodal warmup** | **PASS** | `44.6s`, `/v1/models` returned `["qwen3.5-9b"]` |
| **Loopback Bearer Auth (`--api-key`)** | **PASS** | Unauthenticated `/v1/models` rejected with `HTTP 401`; authorized returned `HTTP 200` |
| **SSE Streaming Text (`stream: true`)** | **PASS** | TTFT `266.5 ms`, total `2502.9 ms`, `48` completion tokens, `21.46 tok/s` |
| **Multimodal JPEG Vision (`bus.jpg`, 882 prompt tokens)** | **PASS** | TTFT `6872.0 ms`, total `8177.5 ms`, `22.21 tok/s`, accurately described electric EMT city bus and pedestrians |
| **OpenAI Native Tool Calling (`--tool-call-parser qwen3_coder`)** | **PASS** | `HTTP 200`, `has_native_tool_calls: true`, exact call `acta__canvas__set_columns` with `{"columns": 3}` |
| **Mid-Stream Cancellation & Recovery** | **PASS** | Cancelled cleanly after 4 SSE chunks; next request returned `"RECOVERED"` with TTFT `217.0 ms` |
| **Graceful Shutdown (`SIGTERM`)** | **PASS** | `Metal worker shutdown complete`, exit code `0`, zero orphan processes |

---

## 3. Bounded Parallel Concurrency Benchmark (1, 2, 4 Simultaneous Requests)

| Concurrency | Wall Time | TTFT p50 | TTFT p95 | Latency p50 | Latency p95 | Per-Request Mean | Aggregate Throughput | Scaling vs c=1 |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **1** | `1.465 s` | `202.6 ms` | `202.6 ms` | `1419.1 ms` | `1419.1 ms` | `22.20 tok/s` | **`18.43 tok/s`** | `1.00×` |
| **2** | `1.708 s` | `323.5 ms` | `361.4 ms` | `1686.2 ms` | `1707.9 ms` | `20.55 tok/s` | **`32.78 tok/s`** | **`1.78×`** |
| **4** | `2.177 s` | `435.4 ms` | `435.6 ms` | `2016.3 ms` | `2176.5 ms` | `17.42 tok/s` | **`51.90 tok/s`** | **`2.82×`** |

- **Process Tree RSS:** `2373.7 MB` (Note: `ps` RSS excludes Metal/IOSurface wired buffers; engine log reported `9.94 GiB` backing KV/state cache at default `0.92` utilization).
- **Thermal Status (`pmset -g therm`):** No thermal throttling warnings observed during spike.
- **Known Non-Fatal CLI Warning:** `vllm-metal 0.30.0` emits an ObjC duplicate-class warning for `AVFFrameReceiver`/`AVFAudioReceiver` between Homebrew `ffmpeg 9.0.2_1` and bundled `cv2` dylibs; no impact on inference or stability was observed.

---

## 4. Production Safety & Fallback Policy Implemented in ACTA

- **Strict Loopback & Per-Launch Bearer Auth:** `ACTALocalVLLMServerManager` binds strictly to `127.0.0.1`, sets `HF_HUB_OFFLINE=1` / `TRANSFORMERS_OFFLINE=1`, generates a fresh 192-bit random `--api-key` per launch (never serialized to JSON or logged in traces), and terminates cleanly on `WallModel.shutdown()`.
- **Fail-Closed Default + Opt-In Local MLX Fallback:** `VLMPreferences.actaVLLMAllowLocalMLXFallback` defaults to `false` (fail-closed). When explicitly enabled by the operator, failures fall back **only** to local in-process MLX — **never** to OpenAI or any remote endpoint.
- **Priority Lane Backpressure:** `ACTALocalVLLMLaneLimiter` reserves interactive slot(s) for operator voice/chat ahead of background tasks and sheds overflowing background work with `VLLM_BACKPRESSURE`.
- **Remaining Phase 4 Gate:** Extended multi-hour live 64-camera RTSP/CoreML/ONNX + `vllm-metal` soak testing and signing/notarization release gates remain in Phase 4.

---

## 5. Wave 3C Stress Measurement — Production `0.65` Utilization, Unified Memory, Thermal State & Camera Analytics Interference

Measured live on the same Apple M5 (24 GB Unified Memory, macOS `27.2.1`) using ACTA's production conservative launch flags:
`--gpu-memory-utilization 0.65 --max-model-len 8192 --max-num-seqs 4 --enable-auto-tool-choice --tool-call-parser qwen3_coder`, offline (`HF_HUB_OFFLINE=1`), loopback `127.0.0.1` + ephemeral `--api-key`.

### Engine Metal Allocation (`0.65` vs `0.92`)
- **Startup + readiness:** `32.1 s` (vs `44.6 s` at `0.92`).
- **Metal / NAX logs:**
  - `NAX prefill attention kernels loaded (M5 tensor units)`
  - `Native paged-attention Metal kernels loaded`
  - `Hybrid shared cache: 320 blocks, 5.16 GiB backing for KV and state` (saves `4.78 GiB` vs default `0.92`).

### Unified Memory (`vm_stat`) & Process Tree Footprint
| Phase | Active | Wired (incl. Metal GPU) | Compressed | Est. Used | Free | `vllm` Tree RSS (3 procs) | Thermal (`ProcessInfo`) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Baseline (before `vllm`)** | `7.774 GiB` | `3.506 GiB` | `2.815 GiB` | `14.095 GiB` | `1.453 GiB` | `—` | `nominal` |
| **Loaded Idle (`0.65`)** | `7.892 GiB` | `3.267 GiB` | `4.026 GiB` | `15.185 GiB` | `0.253 GiB` | `8200.3 MB` | `nominal` |
| **Peak Under 4-Way Mixed + Camera Load** | `1.434 GiB` | **`15.553 GiB`** | `4.605 GiB` | **`21.591 GiB`** | `0.261 GiB` | `8200.3 MB` | **`nominal`** |
| **After `SIGTERM` Shutdown** | `2.019 GiB` | **`3.212 GiB`** | `2.673 GiB` | `7.904 GiB` | **`13.400 GiB`** | `0 MB` (0 procs) | `nominal` |

> **Key Takeaway:** Peak wired Metal + model + multimodal prefill reaches `15.553 GiB` (`21.591 GiB / 24 GiB` est. used) under simultaneous 4-way mixed workload, confirming why `0.65` is the right conservative default on 24 GB Apple Silicon Macs. `SIGTERM` releases all Metal wired memory cleanly (`15.553 GiB → 3.212 GiB`).

### Concurrent 4-Way Mixed `vllm-metal` + 4-Stream Camera Analytics Interference
All 4 `vllm-metal` requests ran **simultaneously** with 4 continuous multi-camera JPEG/frame-processing worker streams (`bus.jpg`, `137.4 KB`):

| Concurrent `vllm-metal` Workload | Status | TTFT | Total Latency | Decode Rate | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Interactive Chat (SSE)** | PASS | `3294.2 ms` | `5414.1 ms` | `13.21 tok/s` | Shared prefill with concurrent 882-tok JPEG |
| **Multimodal JPEG Vision** | PASS | `3906.3 ms` | `7230.3 ms` | `19.25 tok/s` | Accurate electric city bus identification |
| **Native OpenAI `tool_calls`** | PASS | `4655.4 ms` | `5680.5 ms` | `31.22 tok/s` | Emitted `acta__canvas__set_columns` |
| **Background Mid-Stream Cancel** | PASS | `3842.3 ms` | `4031.2 ms` | — | Aborted cleanly after 4 chunks |
| **Post-Cancel Recovery (under cam load)** | PASS | **`184.3 ms`** | `226.0 ms` | **`47.99 tok/s`** | Immediate `"OK"` response |

| Continuous 4-Stream Camera Analytics Metric | Baseline (no `vllm`) | Under 4-Way Mixed `vllm-metal` Load | Delta |
| :--- | :---: | :---: | :---: |
| **Aggregate Frame Throughput** | `2603.2 FPS` | `1847.9 FPS` | `-29.0%` |
| **Frame Processing p50 Latency** | `1.42 ms` | `1.89 ms` | `+0.47 ms` |
| **Frame Processing p95 Latency** | `2.22 ms` | `3.37 ms` | `+1.15 ms` |
| **Stalled Frames (`> 100 ms`)** | `0` | **`0`** | `0` |
