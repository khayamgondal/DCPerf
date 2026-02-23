# FBGEMM Install Script Changes — Conda to System Packages + pip

## Overview

The `install_fbgemm_bench.sh` script was rewritten to remove all dependency on
Miniconda/conda, which is blocked in certain lab and datacenter environments.
The new script uses **apt** (system package manager) and **pip** inside a
**Python venv** instead.

These changes were validated for **GH200 (aarch64)** systems.

## Files Changed

### `install_fbgemm_bench.sh` (rewritten)

| Area | Original (conda-based) | New (apt + pip + venv) |
|------|------------------------|------------------------|
| **Python** | Downloads & installs Miniconda, creates a conda env with `python=3.13` | `apt-get install python3.13 python3.13-venv python3.13-dev`; uses `python3.13 -m venv` |
| **C/C++ compilers** | `conda install gxx_linux-<arch>=14.1.0` from conda-forge | `apt-get install gcc-14 g++-14`; `update-alternatives` for `/usr/bin/gcc` symlinks |
| **Build tools** | `conda install cmake ninja make ...` | `apt-get install cmake ninja-build`; Python packages via `pip install scikit-build wheel ...` |
| **openblas** | `conda install openblas` | `apt-get install libopenblas-dev` |
| **libxcrypt** | `conda install libxcrypt` | `apt-get install libcrypt-dev` |
| **TBB** | `conda install tbb` | `apt-get install libtbb-dev` |
| **ncurses** | `conda install ncurses` | `apt-get install libncurses-dev` |
| **pyOpenSSL** | `conda install pyOpenSSL` + version pinning workaround | `pip install pyOpenSSL` |
| **PyTorch** | `conda run -n env pip install torch==2.8.0 --index-url .../cpu/` | `pip install torch==2.8.0 --index-url .../cpu/` (venv is active) |
| **FBGEMM GPU build** | `conda run -n env python setup.py install --build-variant=cpu` | `python setup.py install --build-variant=cpu` (venv is active) |
| **FBGEMM C++ build** | `source .github/scripts/setup_env.bash && build_fbgemm_library env cmake build_shared static` | Direct CMake invocation: `cmake -S . -B build_shared -DFBGEMM_BUILD_BENCHMARKS=ON -DFBGEMM_LIBRARY_TYPE=static -GNinja` |
| **Environment activation** | `eval "$(conda shell.bash hook)" && conda activate env` | `source ./build/venv/bin/activate` |

### Removed conda-specific functions

The following functions existed solely to work around conda environment quirks
and have been removed entirely:

- `setup_miniconda()` — downloaded and installed Miniconda
- `create_conda_environment()` — created and configured conda env
- `__handle_pyopenssl_version_issue()` — fixed conda-specific pyOpenSSL/cryptography mismatches
- `__handle_libcrypt_header_issue()` — copied `crypt.h` within conda prefix paths
- `__conda_install_glibc()` — installed `sysroot_linux-<arch>` via conda
- `__conda_install_gcc()` — installed GCC via conda-forge
- `__conda_install_clang()` — installed Clang via conda-forge
- `__compiler_post_install_checks()` — verified compilers within conda env
- `install_cxx_compiler()` — orchestrated conda compiler installation
- `env_name_or_prefix()` — determined `-n` vs `-p` flag for conda commands
- `test_binpath()` — checked binary existence via `conda run ... which`
- `test_filepath()` — found files via `conda run ... find`
- `test_python_import_package()` — tested Python imports via `conda run`

### New functions added

- `install_system_dependencies()` — installs all system packages via `apt-get`,
  including automatic PPA detection for Python 3.13 (deadsnakes) and GCC 14
  (ubuntu-toolchain-r) if not in default repos
- `setup_venv()` — creates and activates a Python venv
- `install_build_tools()` — installs Python build packages via pip
- `install_fbgemm_cpu()` — builds FBGEMM C++ library directly with CMake
  instead of sourcing FBGEMM's internal `setup_env.bash` (which itself uses conda)
- `copy_aarch64_libs()` — copies `libc10.so` into the benchmarks directory for
  the aarch64 LD_PRELOAD workaround (see below)

### aarch64 / GH200 specific: `libc10.so` handling fix

The original script had a subtle bug on aarch64: the generated `run.sh`
referenced `libc10.so` at a deep path inside the Miniconda environment
(`build/miniconda/envs/.../site-packages/torch/lib/libc10.so`), but `cleanup()`
at the end of the install deleted the entire `build/` directory, making the path
invalid at runtime.

The new script:
1. Calls `copy_aarch64_libs()` **before** cleanup, which uses
   `python -c "import torch; ..."` to find `libc10.so` and copies it into
   `benchmarks/ai_wdl/fbgemm/libc10.so`
2. The generated `run.sh` now looks for `libc10.so` in the same directory as the
   binary (`${SCRIPT_DIR}/libc10.so`) — simple, self-contained, survives cleanup

### `cleanup_fbgemm_bench.sh` (minor update)

Added removal of `libc10.so` and `run.sh` from the benchmarks directory during
cleanup, alongside the existing binary removals.

### Files NOT changed

- `benchpress/config/benchmarks_ai.yml` — paths (`install_script`, `path`, etc.) are unchanged
- `benchpress/config/jobs_ai.yml` — job definitions and args are unchanged
- `benchpress/plugins/parsers/fbgemm.py` — parser has no conda references
- `packages/adsim/install_fbgemm.sh` — separate adsim benchmark, not part of this flow
- `README.md` (this directory) — benchmark usage documentation unchanged

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GCC_VERSION` | `14` | Major version of GCC to install via apt |
| `PYTHON_VERSION` | `3` | Python version (auto-detected; defaults to system python3) |
| `PYTORCH_VERSION` | `2.8.0` | PyTorch version to install via pip |
| `FBGEMM_VERSION` | `fd32631...` | FBGEMM commit hash to build |

## Prerequisites

- Ubuntu/Debian-based Linux (uses `apt-get`)
- Root **or** `sudo` access (for system package installation)
- Network access to PyPI, GitHub, and `download.pytorch.org`

## Docker / Headless Environment Fixes

The script includes several fixes for running inside Docker containers or
headless environments (e.g. GH200 bare-metal with only GCC 11/12):

| Fix | Detail |
|-----|--------|
| **`run_privileged()`** | Skips `sudo` when running as root (uid 0), avoids "sudo: not found" |
| **`detect_python()`** | Auto-discovers available `python3.X`; no hard-coded version |
| **`detect_gcc()`** | Scans for highest installed `gcc-N`; updates `GCC_VERSION` |
| **Cascading GCC install** | Tries 14 → 13 → 12 with optional PPA; graceful fallback |
| **Git identity for cherry-pick** | Uses `-c user.email`/`-c user.name` for headless containers |
| **arm_neon_sve_bridge.h patch** | Guards `#include` in FBGEMM `Utils.h` with `__GNUC__ >= 13` check for GCC 12 |
| **KleidiAI disable for GCC < 13** | Passes `-DFBGEMM_ENABLE_KLEIDIAI=OFF` to CMake (assembler lacks `fmlal` support) |
| **TBB library bundling** | Uses `find -L` to follow symlinks when collecting `libtbb.so.*` for PyInstaller |
| **`ulimit -n 65536`** | Raises open-files limit in `run.sh` to prevent "too many files open" |
| **`-DFBGEMM_BUILD_TESTS=OFF`** | Skips tests that require `GTest::gmock` (not always available) |
## Manual GCC 14 Installation (Corporate Proxy Workaround)

If the PPA auto-add fails due to a corporate proxy intercepting SSL (e.g.
`ssl.SSLCertVerificationError`), GCC 14 can be installed manually **before**
running the install script. The script's `detect_gcc()` will then pick it up
automatically.

```bash
# 1. Add PPA source file directly (bypasses Python's add-apt-repository)
echo "deb https://ppa.launchpadcontent.net/ubuntu-toolchain-r/test/ubuntu jammy main" \
  > /etc/apt/sources.list.d/ubuntu-toolchain-r-test.list

# 2. Import GPG key using curl -k to skip SSL verification through proxy
curl -ksSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x60c317803a41ba51845e371a1e9377a2ba9ef27f" \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/ubuntu-toolchain-r.gpg

# If curl -k is also blocked, try with explicit proxy:
# curl -k --proxy http://proxy-web.micron.com:80 -sSL \
#   "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x60c317803a41ba51845e371a1e9377a2ba9ef27f" \
#   | gpg --dearmor > /etc/apt/trusted.gpg.d/ubuntu-toolchain-r.gpg

# 3. Update and install
apt-get update
apt-get install -y gcc-14 g++-14

# 4. Verify
g++-14 --version
```

With GCC 14 installed, the `arm_neon_sve_bridge.h` and KleidiAI assembler
issues are resolved natively — the source patches and CMake workarounds in the
script become no-ops.