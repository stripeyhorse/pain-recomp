#!/bin/bash
# Run on beast after push_beast.sh. Use "deps" or "port" to run one stage.
set -euo pipefail

root="$HOME/pain-ps3"
prefix="$root/prefix"
venv="$root/.venv"
jobs="${JOBS:-$(nproc)}"
export PATH="$venv/bin:$prefix/usr/bin:$PATH"
TIMEFORMAT='elapsed %3R s'

setup_tools() {
    local download wheel
    if [[ ! -x "$venv/bin/cmake" || ! -x "$venv/bin/ninja" ]]; then
        if python3 -m venv "$venv"; then
            "$venv/bin/python" -m pip install cmake ninja
        else
            # Debian's base Python can lack ensurepip. Bootstrap from its pip wheel.
            python3 -m venv --without-pip "$venv"
            download="$(mktemp -d "$root/src/pip.XXXXXX")"
            (cd "$download" && apt-get download python3-pip-whl)
            dpkg-deb -x "$download"/python3-pip-whl_*.deb "$prefix"
            wheel="$(find "$prefix/usr/share/python-wheels" -name 'pip-*.whl' -print -quit)"
            PYTHONPATH="$wheel" "$venv/bin/python" -m pip install pip cmake ninja
        fi
    fi
    # Vulkan-Loader requires pkg-config even when all window systems are off.
    if ! command -v pkg-config >/dev/null && ! command -v pkgconf >/dev/null; then
        download="$(mktemp -d "$root/src/pkgconf.XXXXXX")"
        (cd "$download" && apt-get download pkgconf-bin libpkgconf3)
        dpkg-deb -x "$download"/pkgconf-bin_*.deb "$prefix"
        dpkg-deb -x "$download"/libpkgconf3_*.deb "$prefix"
    fi
}

export LD_LIBRARY_PATH="$prefix/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

build_dependency() {
    local name="$1" repo="$2" tag="$3"
    shift 3
    local source="$root/src/$name"
    if [[ ! -d "$source/.git" ]]; then
        git clone --depth 1 --branch "$tag" -- "$repo" "$source"
    fi
    git -C "$source" log -1 --format="$name %H"
    cmake -S "$source" -B "$source/build" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_BUILD_TYPE=Release "$@"
    time cmake --build "$source/build" --parallel "$jobs"
    cmake --install "$source/build"
}

build_deps() {
    mkdir -p "$prefix" "$root/src"
    setup_tools
    build_dependency SDL https://github.com/libsdl-org/SDL.git release-2.32.10 \
        -DSDL_TEST=OFF
    build_dependency Vulkan-Headers https://github.com/KhronosGroup/Vulkan-Headers.git v1.4.309
    build_dependency Vulkan-Loader https://github.com/KhronosGroup/Vulkan-Loader.git v1.4.309 \
        -DBUILD_TESTS=OFF -DBUILD_WSI_XCB_SUPPORT=OFF -DBUILD_WSI_XLIB_SUPPORT=OFF \
        -DBUILD_WSI_WAYLAND_SUPPORT=OFF
    build_dependency glslang https://github.com/KhronosGroup/glslang.git 16.3.0 \
        -DENABLE_GLSLANG_BINARIES=OFF -DENABLE_OPT=0 -DENABLE_HLSL=ON -DBUILD_TESTING=OFF
}

build_port() {
    local port="$root/pain-recomp"
    [[ -s "$port/recompiled/ppu_hle_nids.cpp" && -s "$port/prx/generated/full/catalog.inc" ]] || {
        echo "Missing prepared build inputs. Run push_beast.sh from the workstation." >&2
        exit 1
    }
    cmake -S "$port" -B "$port/build" -G Ninja \
        -DPAIN_USE_PREPARED_PPU=ON -DPORT_SPU_INPUTS= \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_BUILD_TYPE=Release \
        -DPAIN_LEVELSCRIPT_DIR="$port/prx/generated/full" \
        -DPS3RECOMP_DIR="$root/ps3recomp" -DPS3RECOMP_RSX_VULKAN=ON \
        -DPS3RECOMP_VULKAN_INCLUDE_DIR="$prefix/include"
    time cmake --build "$port/build" --target PainRecomp --parallel "$jobs"
}

case "${1:-all}" in
    deps) build_deps ;;
    port) build_port ;;
    all) build_deps; build_port ;;
    *) printf 'Usage: %s [deps|port]\n' "$0" >&2; exit 2 ;;
esac
