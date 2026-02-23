#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.
#
# Modified to use system package manager (apt) and pip with Python venv
# instead of Miniconda/conda. Suitable for environments where conda is
# blocked or unavailable (e.g., lab/datacenter environments).


################################################################################
# Global Configuration Variables
################################################################################

# Directory where benchmark executables will be stored
BENCHMARKS_DIR="$(pwd)/benchmarks/ai_wdl/fbgemm"

# Path to Python virtual environment
VENV_DIR="$(pwd)/build/venv"

# Version of FBGEMM to install
# This is set to a recent commit for now, as the latest release doesn't include the arm-related CMake files fix.
# This will be updated to the latest release once the fix is included.
FBGEMM_VERSION=fd32631d837b41251311099c393af7d7be5cfbf5

# Version of PyTorch to install
PYTORCH_VERSION=2.8.0

# Version of GCC to use for building (major version for apt package naming)
export GCC_VERSION="${GCC_VERSION:-14}"

# Dir to create FBGEMM_CPU benchmark
BUILD_DIR=build_shared

# Python version to use (will be auto-detected if not available)
PYTHON_VERSION="${PYTHON_VERSION:-3}"


################################################################################
# Platform Specific Variables
################################################################################
# Get kernel name (e.g., Linux, Darwin)
# shellcheck disable=SC2155
export KERN_NAME="$(uname -s)"

# Get machine hardware name (e.g., x86_64, aarch64)
# shellcheck disable=SC2155
export MACHINE_NAME="$(uname -m)"

# Combine kernel and machine name (e.g., Linux-x86_64)
# shellcheck disable=SC2155
export PLATFORM_NAME="$KERN_NAME-$MACHINE_NAME"

# Convert kernel name to lowercase for consistency
# shellcheck disable=SC2155
export KERN_NAME_LC="$(echo "$KERN_NAME" | awk '{print tolower($0)}')"

# Convert machine name to lowercase for consistency
# shellcheck disable=SC2155
export MACHINE_NAME_LC="$(echo "$MACHINE_NAME" | awk '{print tolower($0)}')"

# Combine lowercase kernel and machine name (e.g., linux-x86_64)
# shellcheck disable=SC2155
export PLATFORM_NAME_LC="$KERN_NAME_LC-$MACHINE_NAME_LC"


################################################################################
# Utility Functions
################################################################################

# Function to execute a command with multiple retry attempts
# This is useful for commands that might fail due to network issues or race conditions
exec_with_retries () {
  local max_retries="$1"
  local delay_secs=2
  local retcode=0

  # shellcheck disable=SC2086
  for i in $(seq 0 ${max_retries}); do
    # shellcheck disable=SC2145
    echo "[EXEC] [ATTEMPT ${i}/${max_retries}]    + ${@:2}"

    if "${@:2}"; then
      local retcode=0
      break
    else
      local retcode=$?
      echo "[EXEC] [ATTEMPT ${i}/${max_retries}] Command attempt failed."
      echo ""

      if [ "$i" -ne "$max_retries" ]; then
        sleep $delay_secs
      fi
    fi
  done

  if [ $retcode -ne 0 ]; then
    echo "[EXEC] The command has failed after ${max_retries} + 1 attempts; aborting."
  fi

  return $retcode
}

# Function to test network connectivity
test_network_connection () {
  exec_with_retries 3 wget -q --timeout 1 pypi.org -O /dev/null
  local exit_status=$?

  if [ $exit_status == 0 ]; then
    echo "[CHECK] Network does not appear to be blocked."
  else
    echo "[CHECK] Network check exit status: ${exit_status}"
    echo "[CHECK] Network appears to be blocked or suffering from poor connection."
    return 1
  fi
}

# Function to print and execute a command
print_exec () {
  echo "+ $*"
  echo ""

  if eval "$*"; then
    local retcode=0
  else
    local retcode=$?
  fi

  echo ""
  return $retcode
}


################################################################################
# Privilege and Environment Helpers
################################################################################

# Run a command with elevated privileges if needed.
# In Docker containers running as root, sudo is typically not installed.
run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Detect the best available GCC version.
# Verifies the requested GCC_VERSION exists; if not, scans for the highest
# versioned gcc-N in PATH and updates GCC_VERSION accordingly.
detect_gcc() {
  # First check if the requested version is already available
  if command -v "gcc-${GCC_VERSION}" &>/dev/null && command -v "g++-${GCC_VERSION}" &>/dev/null; then
    echo "[DETECT] GCC ${GCC_VERSION} found."
    return 0
  fi

  echo "[WARN] gcc-${GCC_VERSION} / g++-${GCC_VERSION} not found. Scanning for alternatives..."

  # Find the highest versioned gcc-N available
  local best_ver=0
  for gcc_bin in $(compgen -c gcc- 2>/dev/null | grep -E '^gcc-[0-9]+$' | sort -t- -k2 -n -r); do
    local ver="${gcc_bin#gcc-}"
    # Verify matching g++ exists
    if command -v "g++-${ver}" &>/dev/null; then
      best_ver="$ver"
      break
    fi
  done

  # Fallback: check if plain gcc/g++ exist
  if [[ "$best_ver" -eq 0 ]]; then
    if command -v gcc &>/dev/null && command -v g++ &>/dev/null; then
      best_ver=$(gcc -dumpversion | cut -d. -f1)
      echo "[DETECT] Using system default GCC (version ${best_ver})."
      GCC_VERSION="$best_ver"
      return 0
    fi
    echo "[ERROR] No usable GCC compiler found!"
    return 1
  fi

  echo "[DETECT] Found gcc-${best_ver} / g++-${best_ver} as best available."
  GCC_VERSION="$best_ver"
  export GCC_VERSION
  return 0
}

# Detect and set the Python command to use.
# Tries python${PYTHON_VERSION} first, then falls back through common names.
detect_python() {
  local candidates=(
    "python${PYTHON_VERSION}"
    python3
    python
  )
  for cmd in "${candidates[@]}"; do
    if command -v "$cmd" &>/dev/null; then
      PYTHON_CMD="$cmd"
      # Update PYTHON_VERSION to match what's actually available
      PYTHON_VERSION=$($cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "$PYTHON_VERSION")
      echo "[DETECT] Using Python command: $PYTHON_CMD (version $PYTHON_VERSION)"
      return 0
    fi
  done
  echo "[ERROR] No usable Python interpreter found!"
  return 1
}


################################################################################
# System Dependencies Installation
################################################################################
# These functions install system-level packages via apt that were previously
# installed through conda-forge (compilers, build tools, libraries).

install_system_dependencies() {
  echo "################################################################################"
  echo "# Install System Dependencies via apt"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  echo "[SETUP] Updating package lists..."
  run_privileged apt-get update -y

  # Check if the desired Python version is available; if not, add deadsnakes PPA
  if ! apt-cache show "python${PYTHON_VERSION}" &>/dev/null; then
    echo "[SETUP] Python ${PYTHON_VERSION} not found in default repos, adding deadsnakes PPA..."
    run_privileged apt-get install -y software-properties-common
    run_privileged add-apt-repository -y ppa:deadsnakes/ppa
    run_privileged apt-get update -y
  fi

  # Check if the desired GCC version is available; if not, add ubuntu-toolchain-r PPA
  if ! apt-cache show "gcc-${GCC_VERSION}" &>/dev/null; then
    echo "[SETUP] GCC ${GCC_VERSION} not found in default repos, adding ubuntu-toolchain-r PPA..."
    run_privileged apt-get install -y software-properties-common
    run_privileged add-apt-repository -y ppa:ubuntu-toolchain-r/test
    run_privileged apt-get update -y
  fi

  echo "[SETUP] Installing system packages..."
  # NOTE: These packages replace what was previously installed via conda-forge:
  #   - python, python-venv, python-dev  -> replaces conda's Python environment
  #   - gcc-N, g++-N                     -> replaces conda's gxx_linux-<arch>
  #   - cmake, ninja-build               -> replaces conda's cmake, ninja
  #   - libopenblas-dev                   -> replaces conda's openblas (provides <cblas.h>)
  #   - libcrypt-dev                      -> replaces conda's libxcrypt
  #   - libtbb-dev                        -> replaces conda's tbb
  #   - libncurses-dev                    -> replaces conda's ncurses
  #   - libssl-dev                        -> needed for pyOpenSSL

  # Build the package list dynamically — only request python${PYTHON_VERSION}
  # packages if a specific version (e.g. 3.13) was requested.  When
  # PYTHON_VERSION is just "3" we rely on the base python3 package.
  local python_pkgs=()
  if [[ "$PYTHON_VERSION" != "3" ]]; then
    python_pkgs=(
      "python${PYTHON_VERSION}"
      "python${PYTHON_VERSION}-venv"
      "python${PYTHON_VERSION}-dev"
    )
  else
    python_pkgs=(python3 python3-venv python3-dev)
  fi

  # shellcheck disable=SC2086
  run_privileged apt-get install -y \
    "${python_pkgs[@]}" \
    "gcc-${GCC_VERSION}" \
    "g++-${GCC_VERSION}" \
    cmake \
    ninja-build \
    git \
    wget \
    libopenblas-dev \
    libcrypt-dev \
    libtbb-dev \
    libncurses-dev \
    pkg-config \
    libssl-dev \
    build-essential

  # Verify the requested GCC version was actually installed; fall back if not
  detect_gcc

  # Set up compiler alternatives so gcc/g++ point to the detected version
  echo "[SETUP] Setting up compiler alternatives for GCC ${GCC_VERSION}..."
  if [[ -x "/usr/bin/gcc-${GCC_VERSION}" ]]; then
    run_privileged update-alternatives --install /usr/bin/gcc gcc "/usr/bin/gcc-${GCC_VERSION}" 100
    run_privileged update-alternatives --install /usr/bin/g++ g++ "/usr/bin/g++-${GCC_VERSION}" 100
  else
    echo "[WARN] /usr/bin/gcc-${GCC_VERSION} not found; skipping update-alternatives"
  fi

  # Verify compiler installation
  echo "[CHECK] GCC version:"
  gcc --version | head -1
  echo "[CHECK] G++ version:"
  g++ --version | head -1
  echo "[CHECK] CMake version:"
  cmake --version | head -1

  # Auto-detect the actual Python command available after package install
  detect_python

  echo "[SETUP] System dependencies installation complete."
}


################################################################################
# Python Virtual Environment Setup
################################################################################
# Replaces Miniconda setup and conda environment creation.
# Uses Python's built-in venv module instead.

setup_venv() {
  echo "################################################################################"
  echo "# Setup Python Virtual Environment"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  # Remove existing venv to ensure clean setup
  if [ -d "$VENV_DIR" ]; then
    echo "[SETUP] Removing existing virtual environment..."
    rm -rf "$VENV_DIR"
  fi

  # Create new virtual environment using the detected Python command
  echo "[SETUP] Creating Python ${PYTHON_VERSION} virtual environment at ${VENV_DIR}..."
  "${PYTHON_CMD:-python3}" -m venv "$VENV_DIR"

  # Activate the virtual environment — this provides 'python' and 'pip' on PATH
  echo "[SETUP] Activating virtual environment..."
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  # Update PYTHON_VERSION to match what the venv actually provides
  PYTHON_VERSION=$(python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  echo "[SETUP] Venv Python version: ${PYTHON_VERSION}"

  # Upgrade pip to latest version for better package compatibility
  echo "[SETUP] Upgrading pip..."
  (exec_with_retries 3 pip install --upgrade pip) || return 1

  echo "[SETUP] Python version: $(python --version)"
  echo "[SETUP] pip version: $(pip --version)"
  echo "[SETUP] Virtual environment setup complete."
}


################################################################################
# Build Tools Installation
################################################################################
# Installs Python build tools via pip.
# System-level build tools (cmake, ninja, gcc) are installed via apt above.

install_build_tools() {
  echo "################################################################################"
  echo "# Install Python Build Tools via pip"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  test_network_connection || return 1

  # NOTE: These packages replace what was previously installed via conda:
  #   - click, hypothesis, jinja2, numpy, scikit-build, wheel -> same as before (pip)
  #   - pyOpenSSL -> replaces conda-forge pyOpenSSL
  #   - pyinstaller -> for generating standalone executables
  echo "[INSTALL] Installing Python build tools via pip..."
  (exec_with_retries 3 pip install \
    click \
    hypothesis \
    jinja2 \
    numpy \
    scikit-build \
    wheel \
    pyOpenSSL \
    pyinstaller) || return 1

  echo "[INSTALL] Build tools installation complete."
}


################################################################################
# PyTorch Installation
################################################################################

install_pytorch() {
  echo "################################################################################"
  echo "# Install PyTorch ${PYTORCH_VERSION}"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  test_network_connection || return 1

  # Install the CPU variant of PyTorch using pip
  echo "[SETUP] Installing PyTorch CPU variant..."
  (exec_with_retries 3 pip install --pre "torch==${PYTORCH_VERSION}" \
    --index-url https://download.pytorch.org/whl/cpu/) || return 1

  # Test if the PyTorch package loads correctly
  echo "[CHECK] Testing PyTorch installation..."
  python -c "import torch.distributed"

  # Print the installed PyTorch version
  echo "[CHECK] Verifying PyTorch version..."
  python -c "import torch; print('PyTorch version:', torch.__version__)"

  echo "[SETUP] PyTorch installation complete."
}


################################################################################
# FBGEMM Build Functions
################################################################################

# Function to generate a standalone executable from a Python script using PyInstaller
generate_standalone_executable () {
  echo "[SETUP] Setting up paths for PyInstaller..."
  SCRIPT_PATH="bench/tbe/tbe_inference_benchmark.py"
  DIST_DIR="${BENCHMARKS_DIR}"

  # Find all shared libraries (.so files) that need to be included in the executable
  # Detect actual Python version for the _skbuild path (may differ from PYTHON_VERSION variable
  # if the venv was created with a different Python than originally requested)
  echo "[SETUP] Finding shared libraries to include in the executable..."
  local actual_pyver
  actual_pyver=$(python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "${PYTHON_VERSION}")
  # shellcheck disable=SC2086
  SHARED_LIBS=$(find ./_skbuild/linux-${MACHINE_NAME_LC}-${actual_pyver} -name "*.so" -printf "%p:fbgemm_gpu\n")

  # Build the standalone executable using PyInstaller
  echo "[BUILD] Building standalone executable with PyInstaller..."
  # shellcheck disable=SC2046,SC2086
  pyinstaller --onefile --distpath $DIST_DIR $SCRIPT_PATH $(echo $SHARED_LIBS | xargs -n 1 echo --add-binary)

  echo "[SUCCESS] Build complete. Executable is located in the $DIST_DIR directory."
}


################################################################################
# Setup Functions
################################################################################

# Function to set up directories for the build process
setup_directories() {
  echo "[SETUP] Setting up directories for the build process..."

  # Create the benchmarks directory if it doesn't exist
  echo "[SETUP] Creating benchmarks directory..."
  # shellcheck disable=SC2086
  mkdir -p ${BENCHMARKS_DIR}

  # Remove any existing build directory to ensure a clean build environment
  echo "[SETUP] Removing any existing build directory..."
  rm -rf build

  # Create a new build directory
  echo "[SETUP] Creating new build directory..."
  mkdir -p build

  # Enter the build directory (pushd saves the current directory on a stack)
  echo "[SETUP] Changing to build directory..."
  pushd build || exit 1

  echo "[SETUP] Directory setup complete."
}

# Function to clone the FBGEMM repository
clone_fbgemm_repo() {
  echo "################################################################################"
  echo "# Clone FBGEMM Repository (${FBGEMM_VERSION})"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  test_network_connection || return 1

  # Clone the FBGEMM repository along with its submodules
  echo "[SETUP] Cloning repository with submodules..."
  git clone --recursive https://github.com/pytorch/FBGEMM.git "fbgemm_${FBGEMM_VERSION}"
  git -C "fbgemm_${FBGEMM_VERSION}" checkout "${FBGEMM_VERSION}"
  # Cherry-pick the latest commit from the FBGEMM main branch to fix issue https://github.com/pytorch/FBGEMM/pull/5037
  # Use -c flags to set committer identity for headless/Docker environments
  git -C "fbgemm_${FBGEMM_VERSION}" \
    -c user.email="build@local" -c user.name="DCPerf Build" \
    cherry-pick 9df97a7090c2c5edecea4fd08bad11ab8a23284c

  # Disable the postbuild script to prevent race conditions during linking
  echo "[SETUP] Disabling postbuild script..."
  echo "#!/bin/bash" > "fbgemm_${FBGEMM_VERSION}/.github/scripts/fbgemm_gpu_postbuild.bash"

  # Change to the FBGEMM GPU directory
  pushd "fbgemm_${FBGEMM_VERSION}/fbgemm_gpu" || exit 1

  echo "[SETUP] FBGEMM repository setup complete."
}

# Function to install FBGEMM GPU (CPU variant) and create standalone executable
install_fbgemm() {
  echo "################################################################################"
  echo "# Build FBGEMM GPU (CPU variant)"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  # Install the required Python packages for FBGEMM
  echo "[BUILD] Installing Python dependencies..."
  pip install -r requirements.txt

  # Set the build configuration variables
  echo "[BUILD] Setting build configuration variables..."
  export package_name=fbgemm_gpu_cpu
  export package_channel=test
  # shellcheck disable=SC2155
  export python_tag="py${PYTHON_VERSION//./}"
  # shellcheck disable=SC2155
  export ARCH=$(uname -m)
  export python_plat_name="manylinux_2_28_${ARCH}"

  # Determine parallelism for the build
  # shellcheck disable=SC2155
  local core=$(lscpu | grep "Core(s)" | awk '{print $NF}') && echo "core = ${core}" || echo "core not found"
  # shellcheck disable=SC2155
  local sockets=$(lscpu | grep "Socket(s)" | awk '{print $NF}') && echo "sockets = ${sockets}" || echo "sockets not found"
  local re='^[0-9]+$'

  local run_multicore=""
  if [[ $core =~ $re && $sockets =~ $re ]]; then
    local n_core=$((core * sockets))
    run_multicore="-j ${n_core}"
  fi

  # Build and install FBGEMM GPU (CPU variant)
  echo "[BUILD] Building and installing FBGEMM GPU (CPU variant)..."
  # shellcheck disable=SC2086
  print_exec python setup.py ${run_multicore} install --build-variant=cpu

  # Generate a standalone executable
  echo "[BUILD] Generating standalone executable..."
  generate_standalone_executable

  # Return to the FBGEMM root directory
  echo "[BUILD] Returning to FBGEMM root directory..."
  cd .. || exit 1

  echo "[BUILD] FBGEMM GPU installation complete."
}

# Function to build the FBGEMM C++ library and copy benchmark binaries
# This replaces the previous approach of sourcing FBGEMM's setup_env.bash
# and calling build_fbgemm_library, which relied on conda internally.
install_fbgemm_cpu() {
  echo "################################################################################"
  echo "# Build FBGEMM C++ Library"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  # We are in fbgemm_${FBGEMM_VERSION}/ directory (FBGEMM repo root)
  echo "[BUILD] Setting build configuration..."

  # Determine build parallelism
  # shellcheck disable=SC2155
  local core=$(lscpu | grep "Core(s)" | awk '{print $NF}') && echo "core = ${core}" || echo "core not found"
  # shellcheck disable=SC2155
  local sockets=$(lscpu | grep "Socket(s)" | awk '{print $NF}') && echo "sockets = ${sockets}" || echo "sockets not found"
  local re='^[0-9]+$'
  local nproc_val
  nproc_val=$(nproc)

  if [[ $core =~ $re && $sockets =~ $re ]]; then
    nproc_val=$((core * sockets))
  fi

  # Build FBGEMM C++ library directly with CMake
  # This replaces the previous: source .github/scripts/setup_env.bash && build_fbgemm_library
  # IMPORTANT: Explicitly set CMAKE_C_COMPILER / CMAKE_CXX_COMPILER to the
  # GCC version we installed (gcc-14/g++-14).  Without this, CMake picks up the
  # default system compiler (which may be GCC 11 inside Docker) and the build
  # will fail on aarch64 because GCC <12 lacks arm_neon_sve_bridge.h and FP16FML
  # assembler support.
  # Resolve the actual compiler paths – use gcc-N if available, else fall back
  # to plain gcc/g++ (detect_gcc already updated GCC_VERSION for us).
  local cc_path cxx_path
  if command -v "gcc-${GCC_VERSION}" &>/dev/null; then
    cc_path=$(command -v "gcc-${GCC_VERSION}")
    cxx_path=$(command -v "g++-${GCC_VERSION}")
  else
    cc_path=$(command -v gcc)
    cxx_path=$(command -v g++)
  fi
  echo "[BUILD] Using C compiler:   ${cc_path}"
  echo "[BUILD] Using C++ compiler: ${cxx_path}"

  echo "[BUILD] Configuring FBGEMM C++ library with CMake..."
  mkdir -p "${BUILD_DIR}"
  if ! print_exec cmake -S . -B "${BUILD_DIR}" \
    -DFBGEMM_BUILD_BENCHMARKS=ON \
    -DFBGEMM_LIBRARY_TYPE=static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${cc_path}" \
    -DCMAKE_CXX_COMPILER="${cxx_path}" \
    -GNinja; then
    echo "[ERROR] CMake configuration failed. FP16Benchmark and EmbeddingSpMDM8BitBenchmark will NOT be available."
    echo "[ERROR] tbe_inference_benchmark (PyInstaller build) is still usable."
    return 1
  fi

  echo "[BUILD] Building FBGEMM C++ library (parallelism: ${nproc_val})..."
  if ! print_exec cmake --build "${BUILD_DIR}" --parallel "${nproc_val}"; then
    echo "[ERROR] CMake build failed. FP16Benchmark and EmbeddingSpMDM8BitBenchmark will NOT be available."
    return 1
  fi

  # Copy benchmark binaries to the benchmarks directory
  echo "[BUILD] Copying benchmark binaries to ${BENCHMARKS_DIR}..."
  cp "${BUILD_DIR}/bench/FP16Benchmark" "${BENCHMARKS_DIR}/"
  cp "${BUILD_DIR}/bench/EmbeddingSpMDM8BitBenchmark" "${BENCHMARKS_DIR}/"

  echo "[BUILD] FBGEMM C++ library build complete."
}

# Function to copy libc10.so for aarch64 LD_PRELOAD workaround
# On aarch64 (e.g., GH200), libc10.so must be preloaded to avoid
# duplicated cpuinfo_isa symbol definitions that break SVE2 detection.
# This copies libc10.so to the benchmarks directory so it survives
# build directory cleanup.
copy_aarch64_libs() {
  if [[ "$MACHINE_NAME" == "aarch64" || "$MACHINE_NAME" == "arm64" ]]; then
    echo "[SETUP] Copying libc10.so for aarch64 LD_PRELOAD workaround..."
    local torch_lib
    torch_lib=$(python -c "import torch, os; print(os.path.join(os.path.dirname(torch.__file__), 'lib', 'libc10.so'))" 2>/dev/null || true)

    if [[ -n "$torch_lib" && -f "$torch_lib" ]]; then
      cp "$torch_lib" "${BENCHMARKS_DIR}/libc10.so"
      echo "[SETUP] libc10.so copied to ${BENCHMARKS_DIR}/libc10.so"
    else
      echo "[WARN] libc10.so not found in torch installation, LD_PRELOAD workaround will not be available."
      echo "[WARN] tbe_inference_benchmark may use slow path on aarch64."
    fi
  else
    echo "[SETUP] Not aarch64, skipping libc10.so copy."
  fi
}

# Function to clean up build directory
cleanup() {
  echo "[CLEANUP] Performing cleanup operations..."

  # Deactivate virtual environment if active
  if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    echo "[CLEANUP] Deactivating virtual environment..."
    deactivate || true
  fi

  # Return to original directory
  echo "[CLEANUP] Returning to original directory..."
  popd || true

  # Remove the build directory to clean up after the build process
  echo "[CLEANUP] Removing build directory..."
  rm -rf build

  echo "[CLEANUP] Cleanup complete."
}


################################################################################
# Main Function
################################################################################

main() {
  echo "################################################################################"
  echo "# Starting FBGEMM Benchmark Installation"
  echo "# $(date)"
  echo "# Platform: ${PLATFORM_NAME}"
  echo "################################################################################"

  # Set up directories for the build process
  echo "[MAIN] Setting up directories..."
  setup_directories

  # Install system-level dependencies via apt
  echo "[MAIN] Installing system dependencies..."
  install_system_dependencies

  # Set up Python virtual environment (replaces Miniconda + conda env)
  echo "[MAIN] Setting up Python virtual environment..."
  setup_venv

  # Install Python build tools via pip
  echo "[MAIN] Installing build tools..."
  install_build_tools

  # Install PyTorch
  echo "[MAIN] Installing PyTorch..."
  install_pytorch

  # Clone the FBGEMM repository
  echo "[MAIN] Cloning FBGEMM repository..."
  clone_fbgemm_repo

  # Install FBGEMM GPU (CPU variant) and create standalone executable
  echo "[MAIN] Building FBGEMM GPU..."
  install_fbgemm

  # Build FBGEMM C++ library and copy benchmark binaries
  # This may fail if an adequate GCC version is unavailable (e.g. GCC <12 on
  # aarch64).  We allow the script to continue so the PyInstaller-built
  # tbe_inference_benchmark remains usable.
  echo "[MAIN] Building FBGEMM C++ library..."
  install_fbgemm_cpu || echo "[WARN] FBGEMM C++ library build failed; FP16Benchmark and EmbeddingSpMDM8BitBenchmark unavailable."

  # Copy libc10.so for aarch64 platforms (must happen before cleanup removes the venv)
  echo "[MAIN] Copying platform-specific libraries..."
  copy_aarch64_libs

  # Create a run.sh launcher script in the benchmarks directory
cat > "${BENCHMARKS_DIR}/run.sh" <<'EOF'
#!/bin/bash
# Usage: ./run.sh <binary_name> [args...]
set -e

# PyInstaller --onefile executables extract hundreds of bundled shared
# libraries to a temp directory at startup.  The default fd limit (1024)
# is often too low, causing "Too many open files" errors.  Raise it.
ulimit -n 65536 2>/dev/null || ulimit -n 8192 2>/dev/null || true

BIN="$1"
shift

if [[ -z "$BIN" ]]; then
  echo "Usage: $0 <binary_name> [args...]"
  echo "Available binaries:"
  ls "$(dirname "$0")" | grep -E '^(FP16Benchmark|EmbeddingSpMDM8BitBenchmark|tbe_inference_benchmark)$'
  exit 1
fi

BIN_PATH="$(dirname "$0")/$BIN"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: Binary '$BIN' not found or not executable in $(dirname "$0")"
  exit 2
fi

# Get Platform and architecture
OS_TYPE="$(uname -s 2>/dev/null || echo "")"
ARCH_TYPE="$(uname -m 2>/dev/null || echo "")"

# Preload libc10.so on Linux aarch64 platform to avoid duplicated symbol definition for cpuinfo_isa
# in both libc10.so and libtorch_cpu.so.
# Related issue: https://github.com/pytorch/pytorch/issues/166703
# During tbe_inference_benchmark, This duplication causes incorrect SVE2 feature detection in forked child processes,
# leading to Slow Path execution instead of high-performance Auto-Vector Path on aarch64.
if [[ "$OS_TYPE" == "Linux" && "$ARCH_TYPE" == "aarch64" ]]; then
  # Only apply to tbe_inference_benchmark
  if [[ "$BIN" == "tbe_inference_benchmark" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIBC10_PATH="${SCRIPT_DIR}/libc10.so"

    if [[ -f "$LIBC10_PATH" ]]; then
      echo "[INFO] Linux + aarch64 detected, target binary is tbe_inference_benchmark, libc10.so found:"
      echo "       ${LIBC10_PATH}"
      # Inject LD_PRELOAD
      exec env \
        LD_PRELOAD="${LIBC10_PATH}" \
        "${BIN_PATH}" "$@"
    else
      echo "[WARN] Linux + aarch64 detected and target binary is tbe_inference_benchmark,"
      echo "       but libc10.so not found at:"
      echo "       ${LIBC10_PATH}"
      echo "[WARN] Running without LD_PRELOAD"
      exec "${BIN_PATH}" "$@"
    fi
  else
    # Different binary on aarch64 Linux: run as-is
    exec "${BIN_PATH}" "$@"
  fi
else
  # Non-aarch64 or non-Linux platform: run as-is
  exec "${BIN_PATH}" "$@"
fi
EOF

  # Make the run.sh script executable
  chmod +x "${BENCHMARKS_DIR}/run.sh"

  echo "[SETUP] Created launcher script: ${BENCHMARKS_DIR}/run.sh"

  # Clean up temporary files and directories
  echo "[MAIN] Cleaning up..."
  cleanup

  # Output success message
  echo "################################################################################"
  echo "# Installation Complete"
  echo "# Benchmarks installed into ${BENCHMARKS_DIR}"
  echo "# $(date)"
  echo "################################################################################"
}


main
