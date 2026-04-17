# Rust Target CPU Categories

Overview of Rust's default `target-cpu` per architecture, the SIMD instructions each baseline
unlocks, cross-compilation support, and an efficiency ranking.

---

## Default `target-cpu` and SIMD per Architecture

### x86_64 -- `x86-64`

| Property | Value |
|---|---|
| Default CPU | `x86-64` (Linux/Windows/generic), `penryn` (macOS) |
| Tier | **1** (linux-gnu, windows-msvc, apple-darwin) |
| Baseline SIMD | **SSE, SSE2** (mandatory in the x86-64 ABI) |
| macOS SIMD | **SSE, SSE2, SSE3, SSSE3, SSE4.1** (penryn baseline) |
| Notable variants | Windows adds `+sse3`; Fuchsia adds up to `+sse4.2`; Android adds up to `+sse4.2,+popcnt` |
| Width | 128-bit (SSE registers, `__m128`/`__m128d`/`__m128i`) |
| Cross-compilation | **Easy.** Tier 1 with full std and host tools on all major OSes. Toolchains universally available. |

**x86-64 microarchitecture levels** (pass via `-C target-cpu=`):

| Level | Era / Key CPU | SIMD unlocked | Width |
|---|---|---|---|
| `x86-64` (default) | AMD K8 / Pentium 4 (2003) | SSE2 | 128-bit |
| `x86-64-v2` | Nehalem (2008) | SSE3, SSSE3, SSE4.1, **SSE4.2**, POPCNT | 128-bit |
| **`x86-64-v3`** | **Haswell (2013)** | **AVX, AVX2**, FMA, BMI1/2, F16C, MOVBE | **256-bit** |
| `x86-64-v4` | Skylake-X (2017) | **AVX-512** (F, BW, CD, DQ, VL) | **512-bit** |

> `x86-64-v3` / Haswell is the most impactful step -- it doubles SIMD width to 256-bit and is
> supported by virtually all x86_64 CPUs shipped since ~2015. Many projects use it as their
> "modern x86" baseline. `native` uses whatever the build host supports.

---

### i686 -- `pentium4`

| Property | Value |
|---|---|
| Default CPU | `pentium4` (i686), `pentium` (i586) |
| Tier | **1** (linux-gnu, windows-msvc) |
| Baseline SIMD | **SSE, SSE2** (pentium4) or **none** (plain pentium/i586) |
| Width | 128-bit |
| Cross-compilation | **Easy.** Tier 1 with full std. Same toolchains as x86_64. |

---

### aarch64 -- `generic`

| Property | Value |
|---|---|
| Default CPU | `generic` (Linux/Fuchsia/Windows), `apple-m1` (macOS) |
| Tier | **1** (linux-gnu, apple-darwin, windows-msvc) |
| Baseline SIMD | **NEON/AdvSIMD** (mandatory in ARMv8-A, implied by `+v8a`) |
| Apple M1 SIMD | NEON + crypto extensions (AES, SHA-2) |
| Fuchsia variant | Adds `+crc,+aes,+sha2` on top of NEON |
| Width | 128-bit (NEON `V` registers) |
| Cross-compilation | **Easy.** Tier 1 with full std and host tools. Excellent linaro/gcc/llvm toolchain support. |

> Opt-in: `-C target-feature=+sve` or `+sve2` for scalable 128-2048 bit vectors (hardware-dependent).

---

### arm (32-bit) -- `generic`

| Property | Value |
|---|---|
| Default CPU | `generic` (most variants), `cortex-a9` (Vita/VEX) |
| Tier | **2** (linux-gnueabihf), **3** (bare-metal) |
| Baseline SIMD | **None guaranteed** in generic; NEON available on armv7+ with `+neon` |
| Width | 128-bit (NEON `Q` registers) when enabled |
| Cross-compilation | **Easy to moderate.** Tier 2 Linux variants have full std. Bare-metal is `no_std`. |

---

### riscv64 -- `generic-rv64`

| Property | Value |
|---|---|
| Default CPU | `generic-rv64` |
| Tier | **2** with host tools (linux-gnu) |
| Features | `+m,+a,+f,+d,+c,+zicsr,+zifencei` (the "GC" in riscv64**gc**) |
| Baseline SIMD | **None.** The V (vector) extension is **not** in the baseline. |
| Width | N/A without V; with V enabled, scalable 128+ bit (VLEN-dependent) |
| Cross-compilation | **Moderate.** Tier 2 with std and host tools. Toolchains readily available via riscv-gnu-toolchain. |

> Opt-in: `-C target-feature=+v` for the RISC-V Vector extension (RVV 1.0), giving scalable
> SIMD similar in concept to ARM SVE.

---

### riscv32 -- `generic-rv32`

| Property | Value |
|---|---|
| Default CPU | `generic-rv32` |
| Tier | **2** without host tools (linux-gnu), **3** (bare-metal) |
| Features | `+m,+a,+f,+d,+c,+zicsr,+zifencei` (for rv32gc) |
| Baseline SIMD | **None.** Same as riscv64 -- no V extension in baseline. |
| Cross-compilation | **Moderate.** Linux variant has std. Bare-metal variants are `no_std` only. |

---

### wasm32 -- `mvp`

| Property | Value |
|---|---|
| Default CPU | `mvp` (Minimum Viable Product) |
| Tier | **2** without host tools (unknown-unknown, wasip1, wasip2) |
| Baseline SIMD | **None.** The SIMD128 proposal is **not** in MVP. |
| Width | N/A; with simd128 enabled, 128-bit (`v128` type) |
| Cross-compilation | **Moderate/specialized.** Not traditional cross-compilation. Requires wasm-specific tooling (wasm-pack, wasi-sdk). Tier 2 with full std for wasip1/wasip2. |

> Opt-in: `-C target-feature=+simd128` for the WebAssembly SIMD proposal (128-bit fixed-width,
> widely supported in browsers since 2021).

---

### loongarch64 -- `generic`

| Property | Value |
|---|---|
| Default CPU | `generic` |
| Tier | **2** with host tools (linux-gnu, linux-musl) |
| Features | `+f,+d,+lsx,+relax` |
| Baseline SIMD | **LSX** (LoongArch SIMD eXtension) -- 128-bit SIMD **enabled by default** |
| Width | 128-bit (LSX) |
| Cross-compilation | **Moderate.** Tier 2 with std and host tools but very new architecture (2021). Requires recent GCC 15+/Binutils 2.45+. |

> Opt-in: `-C target-feature=+lasx` for LASX (256-bit, analogous to AVX2).

---

### mips32 / mips64 -- `mips32r2` / `mips64r2`

| Property | Value |
|---|---|
| Default CPU | `mips32r2` (32-bit), `mips64r2` (64-bit), `mips32r6`/`mips64r6` (ISA R6 variants) |
| Tier | **2** with host tools (linux-gnu) |
| Features | `+mips32r2,+fpxx,+nooddspreg` |
| Baseline SIMD | **None.** MSA (MIPS SIMD Architecture) is **not** in the baseline. |
| Width | N/A; with MSA, 128-bit |
| Cross-compilation | **Moderate to difficult.** Tier 2 has std but toolchains are declining in availability. Architecture is effectively end-of-life for new designs. |

> Opt-in: `-C target-feature=+msa` for MIPS SIMD Architecture (128-bit).

---

### powerpc64 -- `ppc64` / `ppc64le`

| Property | Value |
|---|---|
| Default CPU | `ppc64` (big-endian), `ppc64le` (little-endian) |
| Tier | **2** with host tools (linux-gnu) |
| Baseline SIMD | **AltiVec/VMX** (implied by LLVM's ppc64 baseline) |
| Width | 128-bit (VMX/AltiVec registers) |
| Cross-compilation | **Moderate.** Tier 2 with std and some host tools. Requires powerpc-specific cross-compiler (readily available on major Linux distros). |

> Opt-in: `-C target-feature=+vsx` for VSX (Vector Scalar Extension, expanded 128-bit with
> double-precision FP SIMD). POWER8+ adds VSX by default.

---

### s390x -- `z10`

| Property | Value |
|---|---|
| Default CPU | `z10` (oldest LLVM-supported, circa 2008) |
| Tier | **2** with host tools (linux-gnu) |
| Baseline SIMD | **None.** z10 predates the Vector Facility (introduced in z13, 2015). |
| Width | N/A; with vector facility, 128-bit |
| Cross-compilation | **Difficult.** Tier 2 with std and host tools, but specialized mainframe hardware. Toolchains exist (s390x-linux-gnu-gcc) but are niche. |

> Opt-in: `-C target-cpu=z13` or later to get the 128-bit Vector Facility.

---

### sparc64 -- `v9`

| Property | Value |
|---|---|
| Default CPU | `v9` |
| Tier | **2** without host tools (linux-gnu) |
| Baseline SIMD | **None.** VIS (Visual Instruction Set) is **not** enabled in baseline v9. |
| Width | N/A; with VIS, 64-bit (paired 32-bit ops) |
| Cross-compilation | **Difficult.** Tier 2 has std but no host tools. Very specialized/legacy hardware. SPARC toolchains are rare. |

> Opt-in: `-C target-feature=+vis,+vis2,+vis3` for SPARC Visual Instruction Set.

---

### m68k -- `M68020`

| Property | Value |
|---|---|
| Default CPU | `M68020` (Linux), `M68010` (bare-metal) |
| Tier | **3** |
| Baseline SIMD | **None.** The 68k architecture has no SIMD extensions. |
| Cross-compilation | **Difficult.** Tier 3, uncertain std support, retrocomputing-only. Requires m68k-elf toolchain. |

---

### hexagon -- `hexagonv60`

| Property | Value |
|---|---|
| Default CPU | `hexagonv60` |
| Tier | **3** |
| Features | `-small-data,+hvx-length128b` |
| Baseline SIMD | **HVX** (Hexagon Vector eXtensions) -- 128-byte (1024-bit) vectors **enabled by default** |
| Width | 1024-bit (128 bytes) per HVX register |
| Cross-compilation | **Difficult.** Tier 3, requires Qualcomm Hexagon SDK. Needs `-Zbuild-std`. QEMU available for testing. |

---

### nvptx64 -- `sm_30`

| Property | Value |
|---|---|
| Default CPU | `sm_30` (NVIDIA Compute Capability 3.0, Kepler) |
| Tier | **2** without host tools |
| Baseline SIMD | **Warp-level SIMT** (not traditional SIMD). 32 threads execute in lockstep. |
| Width | 32-wide warps (effectively 1024-bit for 32-bit ops) |
| Cross-compilation | **Difficult/specialized.** `no_std` only. Generates PTX assembly, not native binaries. Requires `llvm-tools`, nightly Rust, and CUDA runtime. |

---

### xtensa -- `esp32` / `esp32s2` / `esp32s3`

| Property | Value |
|---|---|
| Default CPU | `esp32`, `esp32s2`, or `esp32s3` (per target) |
| Tier | **3** |
| Baseline SIMD | **None** (ESP32/S2). ESP32-S3 has a **PIE** (Processor Instruction Extensions) unit with limited vector ops. |
| Cross-compilation | **Moderate/specialized.** Requires the esp-rs Rust fork with Xtensa LLVM backend. Good community tooling (espup, esp-idf-sys). Std available via ESP-IDF. |

---

### csky -- `ck860fv`

| Property | Value |
|---|---|
| Default CPU | `ck860fv` |
| Tier | **3** |
| Baseline SIMD | **VDSP** (Vector DSP extension, implied by the `v` in `ck860fv`) -- 128-bit vectors |
| Width | 128-bit |
| Cross-compilation | **Difficult.** Tier 3, requires C-SKY-specific toolchain. Very limited ecosystem. |

---

## Efficiency Ranking

Ranking by **architectural power efficiency** (perf/watt) of the category each default
`target-cpu` represents, for general-purpose workloads:

| Rank | Architecture | Default CPU | Baseline SIMD | Efficiency rationale |
|---:|---|---|---|---|
| 1 | **wasm32** | `mvp` | None (opt-in simd128) | Virtual target -- inherits host efficiency with near-zero overhead. No hardware power draw of its own. |
| 2 | **aarch64** | `generic` / `apple-m1` | NEON 128-bit | ARM's efficiency-focused design leads industry perf/watt. Apple Silicon and Graviton dominate efficiency benchmarks. |
| 3 | **riscv64** | `generic-rv64` | None (opt-in V) | Clean-slate RISC design optimized for efficiency. Competitive with ARM at low power; still maturing at the high end. |
| 4 | **xtensa** | `esp32` | None | Ultra-low-power MCU class (milliwatt range). Purpose-built for IoT. Extremely efficient within its tier. |
| 5 | **hexagon** | `hexagonv60` | HVX 1024-bit | DSP architecture optimized for signal-processing perf/watt on mobile SoCs. Best-in-class for its domain. |
| 6 | **loongarch64** | `generic` | LSX 128-bit | Modern RISC design (2021) with decent efficiency, but lags ARM/RISC-V in practice due to smaller fab ecosystem. |
| 7 | **arm (32-bit)** | `generic` | None (opt-in NEON) | Still efficient for embedded, but superseded by aarch64 for anything performance-sensitive. |
| 8 | **x86_64** | `x86-64` | SSE2 128-bit | CISC decode overhead hurts perf/watt vs ARM. The `x86-64` baseline leaves modern efficiency gains (AVX, APX) on the table. |
| 9 | **i686** | `pentium4` | SSE2 128-bit | Same x86 overhead as x86_64 but without 64-bit register file benefits. |
| 10 | **csky** | `ck860fv` | VDSP 128-bit | Niche embedded architecture. Reasonable efficiency but very limited data available. |
| 11 | **powerpc64** | `ppc64le` | AltiVec 128-bit | Designed for throughput (POWER servers), not efficiency. High IPC but high power draw. |
| 12 | **riscv32** | `generic-rv32` | None (opt-in V) | Efficient for embedded but limited by 32-bit addressing for general workloads. |
| 13 | **s390x** | `z10` | None | Mainframe: optimized for RAS and throughput, not perf/watt. z10 is 2008-era silicon. |
| 14 | **mips32/64** | `mips32r2` | None (opt-in MSA) | Aging ISA, surpassed by ARM and RISC-V in every efficiency metric. |
| 15 | **sparc64** | `v9` | None (opt-in VIS) | Legacy server ISA. SPARCv9 baseline is 1990s; essentially EOL for new silicon. |
| 16 | **m68k** | `M68020` | None | 1984-era ISA. Retrocomputing only, no modern efficiency story. |
| 17 | **nvptx64** | `sm_30` | Warp SIMT | GPU compute: massively parallel but power-hungry. Only efficient for embarrassingly parallel workloads. |

---

## Cross-Compilation Summary

| Architecture | Tier | Std | Host tools | Cross-compile difficulty | Notes |
|---|:---:|:---:|:---:|---|---|
| **x86_64** | 1 | Yes | Yes | Easy | Universal toolchain support |
| **i686** | 1 | Yes | Yes | Easy | Same toolchains as x86_64 |
| **aarch64** | 1 | Yes | Yes | Easy | Excellent linaro/llvm toolchains |
| **arm** | 2 | Yes | Partial | Easy--Moderate | Linux variants good; bare-metal is `no_std` |
| **riscv64** | 2 | Yes | Yes | Moderate | riscv-gnu-toolchain readily available |
| **riscv32** | 2 | Yes | No | Moderate | Linux variants have std; bare-metal is `no_std` |
| **wasm32** | 2 | Yes | No | Moderate | Needs wasm-specific tooling (wasm-pack, wasi-sdk) |
| **loongarch64** | 2 | Yes | Yes | Moderate | New arch, needs recent GCC 15+ / Binutils 2.45+ |
| **mips** | 2 | Yes | Partial | Moderate--Difficult | Declining toolchain availability |
| **powerpc64** | 2 | Yes | Partial | Moderate | Available on major Linux distros |
| **s390x** | 2 | Yes | Yes | Difficult | Specialized mainframe hardware |
| **sparc64** | 2 | Yes | No | Difficult | Legacy hardware, rare toolchains |
| **nvptx64** | 2 | No (`no_std`) | No | Difficult | GPU-only, PTX output, needs CUDA + nightly |
| **hexagon** | 3 | Yes | No | Difficult | Requires Qualcomm Hexagon SDK |
| **xtensa** | 3 | Yes | No | Moderate | Good community tooling via esp-rs |
| **csky** | 3 | Yes | No | Difficult | Very limited ecosystem |
| **m68k** | 3 | Unknown | No | Difficult | Retrocomputing, minimal toolchain |

### Tier definitions

- **Tier 1** -- Guaranteed to work. Official pre-built binaries. Full CI testing. Regressions block releases.
- **Tier 2** -- Guaranteed to build. Official pre-built std/core. Limited testing.
- **Tier 3** -- Code exists in-tree. No official builds or CI. Community maintained.

---

## Choosing a CPU Family and Detecting Support at Runtime

### Step 1: Pick your target CPU at compile time

```sh
# List all available CPUs for your target
rustc --print target-cpus --target x86_64-unknown-linux-gnu
rustc --print target-cpus --target aarch64-unknown-linux-gnu

# Compile for a specific CPU family
rustc -C target-cpu=x86-64-v3 ...          # Haswell+ (AVX2)
cargo build --release RUSTFLAGS="-C target-cpu=x86-64-v3"

# Or enable individual features without changing the whole CPU
rustc -C target-feature=+avx2,+fma ...
cargo build --release RUSTFLAGS="-C target-feature=+avx2,+fma"

# Compile for the exact CPU you're sitting on
cargo build --release RUSTFLAGS="-C target-cpu=native"
```

### Step 2: Check support at runtime

Rust provides `is_<arch>_feature_detected!` macros that let you query the
running CPU's capabilities at runtime, so you can ship a single binary that
picks the fastest code path available.

#### Available detection macros

| Architecture | Macro | Stability | Detection method |
|---|---|---|---|
| **x86 / x86_64** | `is_x86_feature_detected!` | **Stable** (1.27) | `CPUID` instruction (OS-independent) |
| **aarch64** | `is_aarch64_feature_detected!` | **Stable** (1.60) | Linux: `getauxval(AT_HWCAP)`; macOS: `sysctlbyname()`; Windows: `IsProcessorFeaturePresent()` |
| **loongarch** | `is_loongarch_feature_detected!` | **Stable** (1.89) | Linux: `CPUCFG` instruction + auxvec |
| **s390x** | `is_s390x_feature_detected!` | **Stable** (1.93) | Linux: `STFLE` instruction + auxvec |
| **arm (32-bit)** | `is_arm_feature_detected!` | Unstable | Linux: `getauxval(AT_HWCAP/AT_HWCAP2)` |
| **riscv** | `is_riscv_feature_detected!` | Unstable | Linux: auxvec + `riscv_hwprobe` syscall (5.19+) |
| **powerpc** | `is_powerpc_feature_detected!` | Unstable | Linux: `getauxval(AT_HWCAP/AT_HWCAP2)` |
| **powerpc64** | `is_powerpc64_feature_detected!` | Unstable | Linux: `getauxval(AT_HWCAP/AT_HWCAP2)` |
| **mips / mips64** | `is_mips_feature_detected!` | Unstable | Linux: `getauxval(AT_HWCAP)` |

Architectures **without** runtime detection: wasm32, nvptx64, xtensa, csky, m68k, hexagon, sparc.

#### Example: runtime multi-versioning on x86_64

```rust
fn process(data: &[f32]) -> f32 {
    // Compile-time check first (zero-cost if feature was enabled globally).
    // Falls through to runtime CPUID check only if needed.
    if is_x86_feature_detected!("avx2") {
        // SAFETY: we just confirmed AVX2 is available
        unsafe { process_avx2(data) }
    } else if is_x86_feature_detected!("sse4.1") {
        unsafe { process_sse41(data) }
    } else {
        process_scalar(data)
    }
}

#[target_feature(enable = "avx2")]
unsafe fn process_avx2(data: &[f32]) -> f32 {
    // compiler can emit AVX2 instructions in this function
    data.iter().sum()
}

#[target_feature(enable = "sse4.1")]
unsafe fn process_sse41(data: &[f32]) -> f32 {
    data.iter().sum()
}

fn process_scalar(data: &[f32]) -> f32 {
    data.iter().sum()
}
```

#### Example: runtime detection on aarch64

```rust
fn compute(data: &[u8]) -> u32 {
    if is_aarch64_feature_detected!("crc") {
        unsafe { compute_with_crc(data) }
    } else {
        compute_fallback(data)
    }
}

#[target_feature(enable = "crc")]
unsafe fn compute_with_crc(data: &[u8]) -> u32 {
    // CRC32 instructions available here
    todo!()
}

fn compute_fallback(data: &[u8]) -> u32 {
    // software CRC
    todo!()
}
```

#### Example: runtime detection on RISC-V (nightly only)

```rust
#![feature(stdarch_riscv_feature_detection)]

fn vector_add(a: &[f64], b: &[f64], out: &mut [f64]) {
    if is_riscv_feature_detected!("v") {
        // RVV available -- use vector extension
        unsafe { vector_add_rvv(a, b, out) }
    } else {
        for i in 0..out.len() {
            out[i] = a[i] + b[i];
        }
    }
}
```

### Key features detectable per architecture

| Architecture | SIMD-relevant features you can query |
|---|---|
| **x86_64** | `sse3`, `ssse3`, `sse4.1`, `sse4.2`, `avx`, `avx2`, `avx512f`, `avx512bw`, `avx512vl`, `fma`, `f16c`, `bmi1`, `bmi2`, `popcnt`, `aes`, `sha` (~80 total) |
| **aarch64** | `neon`, `sve`, `sve2`, `crc`, `aes`, `sha2`, `sha3`, `dotprod`, `i8mm`, `bf16`, `fp16`, `sme`, `sme2`, `lse`, `rcpc` (~100 total) |
| **riscv** | `v` (vector), `b` (bit-manip), `zba`, `zbb`, `zbs`, `zk` (crypto), `zvbb`, `zvbc` (~80 total) |
| **loongarch** | `lsx` (128-bit), `lasx` (256-bit), `lbt`, `lvz`, `f`, `d` |
| **s390x** | `vector`, `vector-enhancements-1`/`2`/`3`, `nnp-assist`, `deflate-conversion` (~23 total) |
| **powerpc64** | `altivec`, `vsx`, `power8`, `power9` |
| **mips** | `msa` |
| **arm** | `neon`, `crc`, `aes`, `sha2`, `i8mm`, `dotprod` |

### How detection works under the hood (`library/std_detect/`)

The entire implementation lives in this repo at `library/std_detect/src/detect/`.

```
is_x86_feature_detected!("avx2")
│
├── compile-time: cfg!(target_feature = "avx2")
│   └── true? → return true immediately (zero cost)
│
└── runtime: cache::test(Feature::avx2 as u32)     ← cache.rs:194
    │
    ├── cache hit (CACHE[idx] != 0)?
    │   └── return bit test on cached usize          ← O(1) atomic load
    │
    └── cache miss (first call):
        └── detect_and_initialize()                  ← cache.rs:177 (#[cold])
            └── os::detect_features()                ← dispatched per OS (mod.rs:35-84)
                │
                ├── x86:        CPUID instruction    ← os/x86.rs
                ├── aarch64 Linux: AT_HWCAP/HWCAP2   ← os/linux/aarch64.rs
                ├── aarch64 macOS: sysctlbyname()     ← os/darwin/aarch64.rs
                ├── aarch64 Windows: IsProcessorFeaturePresent() ← os/windows/aarch64.rs
                ├── riscv Linux: auxvec + riscv_hwprobe syscall  ← os/linux/riscv.rs
                ├── loongarch Linux: auxvec           ← os/linux/loongarch.rs
                ├── s390x Linux: auxvec               ← os/linux/s390x.rs
                ├── powerpc Linux: auxvec             ← os/linux/powerpc.rs
                ├── mips Linux: auxvec                ← os/linux/mips.rs
                ├── freebsd: auxvec                   ← os/freebsd/
                ├── openbsd: auxvec                   ← os/openbsd/
                └── other/miri: empty                 ← os/other.rs
                    │
                    ▼
                cache::Initializer(u128)   →   stored across 3 AtomicUsize slots
```

#### Source file map

| File | Purpose |
|---|---|
| `detect/mod.rs` | Entry point -- `check_for(Feature)`, OS dispatch via `cfg_select!` |
| `detect/cache.rs` | Global 3-slot `AtomicUsize` cache (93-bit capacity), `#[cold]` init |
| `detect/arch/x86.rs` | `Feature` enum + `is_x86_feature_detected!` macro (82 features) |
| `detect/arch/aarch64.rs` | `Feature` enum + `is_aarch64_feature_detected!` macro (65+ features) |
| `detect/arch/riscv.rs` | `Feature` enum + `is_riscv_feature_detected!` macro (80+ features) |
| `detect/arch/loongarch.rs` | `Feature` enum + `is_loongarch_feature_detected!` (14 features) |
| `detect/arch/s390x.rs` | `Feature` enum + `is_s390x_feature_detected!` (23 features) |
| `detect/arch/powerpc.rs` | `Feature` enum + `is_powerpc_feature_detected!` |
| `detect/arch/powerpc64.rs` | `Feature` enum + `is_powerpc64_feature_detected!` |
| `detect/arch/mips.rs` | `Feature` enum + `is_mips_feature_detected!` |
| `detect/os/x86.rs` | CPUID-based detection -- reads leafs 0x01, 0x07, 0x8000_0001, checks XCR0 |
| `detect/os/linux/aarch64.rs` | Reads `AT_HWCAP` + `AT_HWCAP2` bit fields (62 bits), handles Exynos 9810 bug |
| `detect/os/darwin/aarch64.rs` | Queries `hw.optional.arm.FEAT_*` via `sysctlbyname()` |
| `detect/os/windows/aarch64.rs` | Calls `IsProcessorFeaturePresent()` Win32 API |
| `detect/os/linux/riscv.rs` | auxvec for single-letter exts + `riscv_hwprobe` syscall (58 extension bits) + `prctl` for V |
| `detect/os/linux/loongarch.rs` | auxvec-based LSX/LASX/LBT detection |
| `detect/os/linux/s390x.rs` | `STFLE` instruction + auxvec for vector facilities |
| `detect/os/other.rs` | Fallback -- returns empty `Initializer` (no features detected) |

#### Cache design (`cache.rs`)

```rust
// 3 AtomicUsize slots = 93 feature bits on 32-bit, 189 on 64-bit
// Bit layout: slot MSB = "initialized" flag, remaining bits = feature bitmask
static CACHE: [Cache; 3] = [Cache::uninitialized(); 3];

// Per-slot capacity: usize_bits - 1 (the top bit marks "initialized")
// Total: 3 * (usize_bits - 1) = 93 on 32-bit, 189 on 64-bit

// Test path (hot):
pub fn test(bit: u32) -> bool {
    let (relative_bit, idx) = /* map bit to slot */;
    CACHE[idx].test(relative_bit)           // Relaxed atomic load
        .unwrap_or_else(|| detect_and_initialize().test(bit))  // cold path
}
```

The `Initializer` is a `u128` bitmask. On first miss, `detect_and_initialize()`
runs the OS-specific `detect_features()`, splits the 128-bit result across the 3
`AtomicUsize` slots with `Relaxed` ordering, and returns the `Initializer` so the
caller can test it directly (avoiding a second atomic load).

An optional `RUST_STD_DETECT_UNSTABLE` env var can disable specific features at
runtime (behind the `std_detect_env_override` feature flag).

#### Platform-specific detection details

**x86** (`os/x86.rs`): Entirely OS-independent -- uses the `CPUID` instruction directly.
Queries leaf 0x01 (basic features), leaf 0x07 (extended features + subleaves), and leaf
0x8000_0001 (AMD extended). Also reads `XCR0` via `_xgetbv(0)` to verify OS support for
AVX (bits 1-2), AVX-512 (bits 5-7), AMX (bits 17-18), and APX (bit 19). Includes a
workaround for Skylake erroneously reporting BMI1/BMI2 (Intel errata SKL052).

**aarch64 Linux** (`os/linux/aarch64.rs`): Maps `AT_HWCAP` (bits 0-31) and `AT_HWCAP2`
(bits 0-62) to an `AtHwcap` struct with 60+ boolean fields. Feature dependencies are
enforced in code (e.g., SVE2 requires SVE which requires ASIMD which requires FP). Special
handling for Samsung Exynos 9810 (big.LITTLE ISA mismatch on pre-Android-9).

**aarch64 macOS** (`os/darwin/aarch64.rs`): Calls `sysctlbyname("hw.optional.arm.FEAT_*")`
for each feature individually. Returns `i32` -- nonzero means supported.

**RISC-V Linux** (`os/linux/riscv.rs`): Three-tier detection:
1. Auxiliary vector (`AT_HWCAP`) for single-letter extensions (I, M, A, F, D, C, V)
2. `riscv_hwprobe` syscall (nr 258, Linux 5.19+) with `RISCV_HWPROBE_KEY_IMA_EXT_0` for
   58 multi-letter extensions
3. `prctl(PR_RISCV_V_GET_CONTROL)` to check if the V extension is actually enabled on the
   current thread (not just supported by hardware)

### Decision flowchart: compile-time vs runtime

```
Do you control the deployment hardware?
├── YES (e.g., your own servers, known embedded target)
│   └── Use -C target-cpu=<specific>
│       e.g., target-cpu=x86-64-v3, target-cpu=apple-m1, target-cpu=native
│       ✓ Whole program benefits, no branching overhead
│
└── NO (e.g., distributed binary, crate on crates.io)
    └── Compile with the LOWEST baseline you need to support
        (usually the default target-cpu)
        │
        ├── Manual: is_<arch>_feature_detected! + #[target_feature]
        │   ✓ No dependency, fine for a few hot functions
        │
        └── Ergonomic: use `pulp` crate (see next section)
            ✓ Single generic impl, safe, multi-arch, zero boilerplate
```

---

## `pulp` -- safe runtime SIMD dispatch

[`pulp`](https://github.com/sarah-quinones/pulp) (by sarah quinones) wraps the
manual `#[target_feature]` + `is_x86_feature_detected!` pattern into a single
safe, generic API. You write your algorithm once against a `Simd` trait, and
`pulp` monomorphizes it for every SIMD tier the current CPU supports, then
dispatches at runtime.

### Architecture support

| Architecture | Tiers detected | SIMD structs | Detection method |
|---|---|---|---|
| **x86 / x86_64** | SSE2, SSE4.2, AVX2+FMA, AVX-512 | `V1`, `V2`, `V3`, `V4` | `CPUID` (via `std` or `raw-cpuid` on `no_std`) |
| **aarch64** | NEON, NEON+FCMA | `Neon`, `NeonFcma` | `std::is_aarch64_feature_detected!` (Linux: auxvec, macOS: sysctl, Windows: Win32 API) |
| **wasm32** | simd128, relaxed-simd | `Simd128`, `RelaxedSimd` | Custom `AtomicBool` flag (toggled by host via `enable_simd128()`) |
| **Everything else** | Scalar only | `Scalar` | Compile-time `cfg!` fallback |

> RISC-V V is **not yet supported** -- falls back to `Scalar`.

### x86 SIMD tiers in detail

These match the `x86-64-v*` microarchitecture levels from the earlier table:

| Struct | Required features | Maps to | Register width |
|---|---|---|---|
| `V1` | `sse`, `sse2`, `fxsr` | x86-64 baseline | 128-bit |
| `V2` | V1 + `sse3`, `ssse3`, `sse4.1`, `sse4.2`, `popcnt` | ~`x86-64-v2` | 128-bit |
| `V3` | V2 + `avx`, `avx2`, `bmi1`, `bmi2`, `fma`, `lzcnt` | **`x86-64-v3` (Haswell)** | 256-bit |
| `V4` | V3 + `avx512f`, `avx512bw`, `avx512cd`, `avx512dq`, `avx512vl` | ~`x86-64-v4` | 512-bit |

`V4` is gated behind a `x86-v4` cargo feature flag.

### How it works

```
Arch::new()                     // probe CPU features once
  │
  ├─ x86:  V4 available? → V3 available? → Scalar
  ├─ arm:  NeonFcma? → Neon? → Scalar
  └─ wasm: RelaxedSimd? → Simd128? → Scalar
      │
      ▼
arch.dispatch(my_op)            // match on best variant
  │
  ├─ Arch::V3(simd) => Simd::vectorize(simd, my_op)
  │       │
  │       └── calls inner fn annotated with
  │           #[target_feature(enable = "avx2,fma,bmi1,...")]
  │           so LLVM can emit wide instructions
  │
  └─ Arch::Scalar => Simd::vectorize(Scalar, my_op)
          │
          └── scalar fallback, same generic code
```

The `vectorize()` boundary is where the `#[target_feature]` attributes live.
A "fastcall" optimization passes small closures (up to 8 `usize`) by value
through `MaybeUninit<usize>` parameters instead of a pointer, so the closure
body gets inlined inside the target-feature-annotated function -- no call overhead.

### The `Simd` trait

Every tier (`Scalar`, `V1`..`V4`, `Neon`, `Simd128`, ...) implements `Simd`,
which defines associated types for every vector width and operations on them:

```rust
// Simplified -- the real trait has hundreds of methods
pub trait Simd: Copy + Send + Sync + 'static {
    const IS_SCALAR: bool;
    const REGISTER_COUNT: usize;

    // Associated vector types scale with the tier
    type f32s;   // V3 → f32x8,  Scalar → f32,   Neon → f32x4
    type f64s;   // V3 → f64x4,  Scalar → f64,   Neon → f64x2
    type u8s;    // V3 → u8x32,  Scalar → u8,    Neon → u8x16
    type i32s;   // V3 → i32x8,  Scalar → i32,   Neon → i32x4
    type c32s;   // complex f32 (pairs)
    type c64s;   // complex f64 (pairs)
    // ... mask types, index types, etc.

    // Operations
    fn add_f32s(self, a: Self::f32s, b: Self::f32s) -> Self::f32s;
    fn mul_f64s(self, a: Self::f64s, b: Self::f64s) -> Self::f64s;
    fn mul_add_f32s(self, a: Self::f32s, b: Self::f32s, c: Self::f32s) -> Self::f32s;
    fn cmp_lt_f32s(self, a: Self::f32s, b: Self::f32s) -> Self::m32s;
    fn reduce_sum_f32s(self, a: Self::f32s) -> f32;
    fn splat_f32s(self, val: f32) -> Self::f32s;
    // ... hundreds more: bitwise, shuffle, load/store, complex math, etc.
}
```

### The `WithSimd` trait (your code goes here)

```rust
pub trait WithSimd {
    type Output;
    fn with_simd<S: Simd>(self, simd: S) -> Self::Output;
}
```

You implement `WithSimd` for a struct carrying your data, and the single
`with_simd` body works across all architectures and SIMD widths because it's
generic over `S: Simd`.

### Example: pulp vs manual

**Manual approach** (from the earlier section):

```rust
// Three separate functions, all unsafe, architecture-specific
fn process(data: &[f32]) -> f32 {
    if is_x86_feature_detected!("avx2") {
        unsafe { process_avx2(data) }
    } else if is_x86_feature_detected!("sse4.1") {
        unsafe { process_sse41(data) }
    } else {
        process_scalar(data)
    }
}
#[target_feature(enable = "avx2")]
unsafe fn process_avx2(data: &[f32]) -> f32 { /* ... */ }
#[target_feature(enable = "sse4.1")]
unsafe fn process_sse41(data: &[f32]) -> f32 { /* ... */ }
fn process_scalar(data: &[f32]) -> f32 { /* ... */ }
```

**With `pulp`:**

```rust
use pulp::Simd;

struct DotProduct<'a> {
    a: &'a [f32],
    b: &'a [f32],
}

impl pulp::WithSimd for DotProduct<'_> {
    type Output = f32;

    // ONE implementation -- works on Scalar, V3 (AVX2), Neon, wasm, etc.
    fn with_simd<S: Simd>(self, simd: S) -> f32 {
        let (a_head, a_tail) = S::as_simd_f32s(self.a);
        let (b_head, b_tail) = S::as_simd_f32s(self.b);

        let mut acc = simd.splat_f32s(0.0);
        for (&a, &b) in a_head.iter().zip(b_head) {
            acc = simd.mul_add_f32s(a, b, acc);  // FMA when available
        }

        let mut sum = simd.reduce_sum_f32s(acc);
        for (&a, &b) in a_tail.iter().zip(b_tail) {
            sum += a * b;  // scalar remainder
        }
        sum
    }
}

// Usage -- one line, safe, auto-dispatches
let result = pulp::Arch::new().dispatch(DotProduct { a: &xs, b: &ys });
```

This single `with_simd` body compiles to:
- **x86 V3**: 256-bit `vfmadd231ps` (AVX2 FMA on `f32x8`)
- **x86 V4**: 512-bit `vfmadd231ps` (AVX-512 FMA on `f32x16`)
- **aarch64 Neon**: 128-bit `fmla` (NEON FMA on `f32x4`)
- **wasm simd128**: 128-bit `f32x4.mul` + `f32x4.add`
- **Scalar**: plain `f32` multiply-accumulate

No `unsafe`, no architecture-specific code, no manual dispatch.

### Comparison: std detection vs `pulp`

| | `std` macros + `#[target_feature]` | `pulp` |
|---|---|---|
| **Safety** | `unsafe` on every SIMD function call | Safe -- unsafety hidden in generated wrappers |
| **Boilerplate** | N functions x M architectures | 1 generic `with_simd` body |
| **Dispatch** | Manual `if`/`else` chains | `Arch::new().dispatch(op)` |
| **Cross-platform** | Must rewrite per arch | Same code for x86/ARM/wasm/scalar |
| **`no_std`** | Not supported (detection needs `std`) | Supported (uses `raw-cpuid` on x86) |
| **Complex numbers** | No support | Built-in `c32`/`c64` with SIMD ops |
| **Detection cache** | 3 `AtomicUsize` (std_detect) | Two-level: per-feature bits + per-struct `AtomicU8` |
| **Inlining** | Up to LLVM; function boundary can block it | Fastcall trick passes closures by value through registers |
| **Stability** | Stable (x86, aarch64); nightly (others) | Stable Rust on all supported archs |
| **RISC-V** | Yes (nightly) | No (falls back to Scalar) |
| **SVE / SME** | Yes (detection only) | No (NEON only on aarch64) |
| **AVX-512** | Yes | Yes (behind `x86-v4` feature flag) |

### When to use which

```
Do you need RISC-V V, SVE, or s390x vectors?
├── YES → std macros (pulp doesn't cover these yet)
│
└── NO
    ├── One or two hot functions on a single arch?
    │   └── std macros are fine, less dependency
    │
    └── Anything more?
        └── Use pulp
            ✓ Less code  ✓ Safer  ✓ Cross-platform  ✓ no_std
```
