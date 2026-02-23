# FBGEMM Install Script Changes — Conda to System Packages + pip

## Overview

The `install_fbgemm_bench.sh` script was rewritten to remove all dependency on
Miniconda/conda, which is blocked in certain lab and datacenter environments.
The new script uses **pip** inside a **Python venv** instead, and expects
system packages to be **pre-installed manually** by the user.

These changes were validated for **GH200 (aarch64)** systems running
Ubuntu 22.04 in Docker.

---

## Prerequisites — Manual Installation Required

The script **does NOT install system packages**. All packages below must be
installed **before** running the install script. The script validates their
presence at startup and will abort with a clear error if anything is missing.

### System Packages (apt)

These correspond to what the original conda script installed automatically:

```bash
apt-get update
apt-get install -y \
  python3 python3-venv python3-dev \
  gcc-14 g++-14 \
  cmake \
  ninja-build \
  git \
  wget \
  build-essential \
  pkg-config \
  libopenblas-dev \
  libcrypt-dev \
  libtbb-dev \
  libncurses-dev \
  libssl-dev
```

#### Version mapping (original conda → required apt)

| Original (conda-forge) | Required apt package | Minimum version | Notes |
|---|---|---|---|
| `python=3.13` | `python3` + `python3-venv` + `python3-dev` | 3.10+ | Original used 3.13; any Python 3.10+ works. Script auto-detects. |
| `gxx_linux-aarch64=14.1.0` | **`gcc-14` + `g++-14`** | **14** | **Critical.** GCC < 14 causes build failures on aarch64 (`arm_neon_sve_bridge.h`, `fmlal` instructions). See GCC 14 install instructions below. |
| `clangxx=16.0.6` | Not required | — | Original installed Clang 16 as host compiler. New script uses GCC only. |
| `cmake` | `cmake` | 3.22+ | |
| `ninja` | `ninja-build` | 1.10+ | |
| `make` | `build-essential` | — | Includes make, gcc base, etc. |
| `openblas` | `libopenblas-dev` | — | Provides `<cblas.h>` |
| `libxcrypt` | `libcrypt-dev` | — | Provides `<crypt.h>` |
| `tbb` | `libtbb-dev` | — | Headers for build. At runtime, PyTorch's bundled TBB is used (see TBB section). |
| `ncurses` | `libncurses-dev` | — | Silences libtinfo errors |
| `sysroot_linux-aarch64=2.17` | Not required | — | System GLIBC is used directly |

### GCC 14 Installation (Ubuntu 22.04 — PPA required)

GCC 14 is **not** in Ubuntu 22.04's default repos. You need the
`ubuntu-toolchain-r/test` PPA. If your environment has a corporate proxy
that blocks `add-apt-repository` (SSL cert errors), use this manual method:

```bash
# 1. Add PPA source file directly (bypasses Python's add-apt-repository)
echo "deb https://ppa.launchpadcontent.net/ubuntu-toolchain-r/test/ubuntu jammy main" \
  > /etc/apt/sources.list.d/ubuntu-toolchain-r-test.list

# 2. Import GPG key (use -k to skip SSL verification through proxy)
curl -ksSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x60c317803a41ba51845e371a1e9377a2ba9ef27f" \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/ubuntu-toolchain-r.gpg

# If curl -k is also blocked, try with explicit proxy:
# curl -k --proxy http://proxy-web.micron.com:80 -sSL \
#   "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x60c317803a41ba51845e371a1e9377a2ba9ef27f" \
#   | gpg --dearmor > /etc/apt/trusted.gpg.d/ubuntu-toolchain-r.gpg

# 3. Update and install
apt-get update
apt-get install -y gcc-14 g++-14

# 4. Set as default (optional but recommended)
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100
update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100

# 5. Verify
gcc-14 --version   # Should show 14.x.x
g++-14 --version
```

#### Why GCC 14 is required on aarch64

| Issue | GCC < 13 | GCC 13 | GCC 14 |
|---|---|---|---|
| `arm_neon_sve_bridge.h` header | Missing — fatal error | Present | Present |
| KleidiAI `fmlal` instructions | Assembler rejects | May work | Works |
| FP16FML support | Partial | Yes | Yes |
| SVE2 code generation | Limited | Good | Best |

If GCC 14 is available, all source patches and CMake workarounds in the
script become no-ops.

### Python Build Tools (installed by script via pip)

These are installed **automatically** by the script inside the venv. Versions
shown are what the original conda script used:

| Package | Version constraint | Notes |
|---|---|---|
| `click` | latest | |
| `hypothesis` | latest | |
| `jinja2` | latest | |
| `numpy` | latest | |
| `scikit-build` | latest | |
| `wheel` | latest | |
| `pyOpenSSL` | `>22.1.0` | Original conda pinned this; now pip-pinned too |
| `pyinstaller` | latest | For creating standalone `tbe_inference_benchmark` binary |
| `torch` | `==2.8.0` (CPU) | `pip install --pre torch==2.8.0 --index-url https://download.pytorch.org/whl/cpu/` |

---

## TBB Runtime Fix — Using PyTorch's Bundled TBB

The most critical runtime fix: **the PyInstaller standalone executable now
bundles TBB from PyTorch's `torch/lib/` directory** instead of from the system
`libtbb-dev` package.

### Root cause

`fbgemm_gpu_py.so` is built by `python setup.py install --build-variant=cpu`,
which links against PyTorch's internal TBB (via `torch.utils.cmake_prefix_path`).
PyTorch 2.8.0 bundles **TBB 2021.11+** in `torch/lib/libtbb.so.2`.

The system `libtbb-dev` on Ubuntu 22.04 provides **TBB 2021.5.0** with a
**different ABI**. If the system TBB is bundled instead, the PyInstaller binary
crashes at startup with:

```
undefined symbol: _ZN3tbb6detail2r18allocateERPNS0_2d117small_object_poolEmRKNS2_14execution_dataE
```

### Fix

The `generate_standalone_executable()` function now:
1. Detects PyTorch's lib directory: `torch/lib/`
2. Bundles `libtbb.so.2`, `libtbbmalloc.so.2`, `libtbbmalloc_proxy.so.2` from there
3. Falls back to system TBB only if torch lib dir cannot be found

---

## Files Changed

### `install_fbgemm_bench.sh` (rewritten)

| Area | Original (conda-based) | New (system + pip + venv) |
|------|------------------------|--------------------------|
| **Package install** | Script installs everything via conda | Script **validates** pre-installed packages; does NOT install apt packages |
| **Python** | Miniconda + `conda create python=3.13` | System `python3` + `python3 -m venv` |
| **C/C++ compilers** | `conda install gxx_linux-<arch>=14.1.0` + `clangxx=16.0.6` | Pre-installed `gcc-14` / `g++-14` (GCC only, no Clang) |
| **Build tools** | `conda install cmake ninja make tbb openblas ...` | Pre-installed via `apt`; pip packages installed by script |
| **TBB bundling** | Not bundled (conda env available at runtime) | PyTorch's `torch/lib/libtbb.so.2` bundled into PyInstaller binary |
| **PyTorch** | `conda run pip install torch==2.8.0` | `pip install torch==2.8.0` (venv active) |
| **FBGEMM GPU build** | `conda run python setup.py install` | `python setup.py install` (venv active) |
| **FBGEMM C++ build** | `source setup_env.bash && build_fbgemm_library` | Direct CMake: `cmake -S . -B build_shared -GNinja` |
| **Environment** | `conda activate` | `source venv/bin/activate` |

### Removed conda-specific functions

- `setup_miniconda()`, `create_conda_environment()`
- `__handle_pyopenssl_version_issue()`, `__handle_libcrypt_header_issue()`
- `__conda_install_glibc()`, `__conda_install_gcc()`, `__conda_install_clang()`
- `__compiler_post_install_checks()`, `install_cxx_compiler()`
- `env_name_or_prefix()`, `test_binpath()`, `test_filepath()`
- `test_python_import_package()`
- `install_system_dependencies()` (replaced by `validate_system_dependencies()`)

### New/modified functions

| Function | Purpose |
|---|---|
| `validate_system_dependencies()` | Checks all required packages are present; prints what's missing |
| `detect_gcc()` | Finds highest available `gcc-N`; updates `GCC_VERSION` |
| `detect_python()` | Auto-discovers available Python 3.x interpreter |
| `run_privileged()` | Runs with sudo or directly if root (Docker compat) |
| `setup_venv()` | Creates and activates Python venv |
| `install_build_tools()` | pip-installs Python build packages (with `pyOpenSSL>22.1.0`) |
| `install_fbgemm_cpu()` | Direct CMake build with `-DFBGEMM_BUILD_TESTS=OFF`, `-DFBGEMM_ENABLE_KLEIDIAI=OFF` for GCC < 13 |
| `copy_aarch64_libs()` | Copies `libc10.so` for LD_PRELOAD workaround |
| `generate_standalone_executable()` | Bundles PyTorch's TBB into PyInstaller binary |

### `cleanup_fbgemm_bench.sh` (minor update)

Added removal of `libc10.so` and `run.sh` from the benchmarks directory.

### `run.sh` (generated launcher)

- Added `ulimit -n 65536` to prevent "too many open files" errors
- Uses `${SCRIPT_DIR}/libc10.so` instead of conda env path

---

## Docker / Headless Environment Fixes

| Fix | Detail |
|-----|--------|
| `run_privileged()` | Skips `sudo` when running as root (uid 0) |
| `detect_python()` | Auto-discovers available `python3.X`; no hard-coded version |
| `detect_gcc()` | Scans for highest installed `gcc-N` |
| Git cherry-pick identity | Uses `-c user.email`/`-c user.name` for headless containers |
| `arm_neon_sve_bridge.h` patch | Guards include with `__GNUC__ >= 13` (for GCC 12 fallback) |
| KleidiAI disable | `-DFBGEMM_ENABLE_KLEIDIAI=OFF` when GCC < 13 |
| TBB from torch | Bundles `torch/lib/libtbb.so.2` instead of system libtbb |
| `ulimit -n 65536` | Raises fd limit in `run.sh` |
| `-DFBGEMM_BUILD_TESTS=OFF` | Skips tests requiring `GTest::gmock` |

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GCC_VERSION` | `14` | Major version of GCC expected (auto-detected if not set) |
| `PYTHON_VERSION` | `3` | Python version (auto-detected; defaults to system python3) |
| `PYTORCH_VERSION` | `2.8.0` | PyTorch version installed via pip |
| `FBGEMM_VERSION` | `fd32631...` | FBGEMM commit hash |

---

## Quick Start

```bash
# 1. Install all system prerequisites (see apt-get command above)
# 2. Install GCC 14 (see PPA instructions above)
# 3. Run the install script:
./benchpress_cli.py install fbgemm_embedding_a_single

# Or directly:
cd packages/ai_wdl/fbgemm
bash install_fbgemm_bench.sh
```

## Files NOT changed

- `benchpress/config/benchmarks_ai.yml` — paths unchanged
- `benchpress/config/jobs_ai.yml` — job definitions unchanged
- `benchpress/plugins/parsers/fbgemm.py` — no conda references
- `packages/adsim/install_fbgemm.sh` — separate adsim benchmark
