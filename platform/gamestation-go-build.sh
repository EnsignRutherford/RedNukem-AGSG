#!/usr/bin/env bash
# Build and stage the Linux/armhf Rednukem package for Atari GameStation Go.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: platform/gamestation-go-build.sh [make-target...]

Builds Rednukem for Atari GameStation Go and stages a deployable package.
The default make target is rr, which creates the rednukem executable.

Required environment:
  SYSROOT       Root of the GameStation Go Dice/Debian Stretch ARMHF SDK.

Optional environment:
  GSG_RENDERER
                software (default) builds the software-rendered package.
                dn64-gl builds the SDL/OpenGL Duke Nukem 64 package in
                package/gamestation-go-dn64 by default.
  LEGACY_SYSROOT
                Cached Debian Stretch ARMHF headers and linker scripts
                (default: /home/lebla/armhf-stretch-sysroot).
  LEGACY_CXX_ROOT
                Cached GCC 8 compatibility headers and shared libstdc++
                (default: ${LEGACY_SYSROOT}/opt/mame-gcc8/usr).
                Its GCC 13 compiler support objects remain in use, while
                cached Stretch PIE start/end files preserve constructor
                initialization with the target glibc.
  CROSS         Toolchain prefix (default: arm-linux-gnueabihf-).
  READELF       Target readelf command (default: ${CROSS}readelf, then readelf).
  OUTPUT_DIR    Package directory (default depends on GSG_RENDERER).
  BUILD_DIR     Object directory (default depends on GSG_RENDERER).
  RUNTIME_LIBDIR
                Colon-separated target runtime library directories. Defaults
                to the SDK's runtime staging directory and ARMHF library paths.
  TARGET_CFLAGS Extra target compiler flags.
  TARGET_LDFLAGS
                Extra target linker flags.

The script builds a 32-bit ARMv7-A hard-float NEON PIE with
/lib/ld-linux-armhf.so.3, stages every non-baseline DT_NEEDED dependency in
lib/, and recursively validates the staged ELF dependency closure with readelf.
EOF
}

die() {
    printf 'gamestation-go-build: %s\n' "$*" >&2
    exit 1
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

: "${SYSROOT:?Set SYSROOT to the GameStation Go SDK sysroot.}"
[[ -d "$SYSROOT" ]] || die "sysroot does not exist: $SYSROOT"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GSG_RENDERER="${GSG_RENDERER:-software}"
case $GSG_RENDERER in
    software)
        use_opengl=0
        default_output_dir="$root/package/gamestation-go"
        default_build_dir="$root/obj/gamestation-go"
        ;;
    dn64-gl)
        use_opengl=1
        default_output_dir="$root/package/gamestation-go-dn64"
        default_build_dir="$root/obj/gamestation-go-dn64"
        ;;
    *)
        die "unsupported GSG_RENDERER '$GSG_RENDERER' (expected software or dn64-gl)"
        ;;
esac

LEGACY_SYSROOT="${LEGACY_SYSROOT:-/home/lebla/armhf-stretch-sysroot}"
LEGACY_CXX_ROOT="${LEGACY_CXX_ROOT:-$LEGACY_SYSROOT/opt/mame-gcc8/usr}"
CROSS="${CROSS:-arm-linux-gnueabihf-}"
OUTPUT_DIR="${OUTPUT_DIR:-$default_output_dir}"
BUILD_DIR="${BUILD_DIR:-$default_build_dir}"
TARGET_CFLAGS="${TARGET_CFLAGS:-}"
TARGET_LDFLAGS="${TARGET_LDFLAGS:-}"
RUNTIME_LIBDIR="${RUNTIME_LIBDIR:-}"

[[ -d "$LEGACY_SYSROOT" ]] || die "legacy sysroot does not exist: $LEGACY_SYSROOT"
[[ -d "$LEGACY_CXX_ROOT/include/c++/8" ]] ||
    die "legacy C++ headers do not exist: $LEGACY_CXX_ROOT/include/c++/8"
[[ -f "$LEGACY_CXX_ROOT/lib/arm-linux-gnueabihf/libstdc++.so.6" ]] ||
    die "legacy C++ runtime does not exist: $LEGACY_CXX_ROOT/lib/arm-linux-gnueabihf/libstdc++.so.6"
command -v "${CROSS}gcc" >/dev/null || die "missing compiler: ${CROSS}gcc"
command -v "${CROSS}g++" >/dev/null || die "missing compiler: ${CROSS}g++"

legacy_start_dir="$LEGACY_SYSROOT/usr/lib/arm-linux-gnueabihf"
for startup_file in Scrt1.o crti.o crtn.o; do
    [[ -f "$legacy_start_dir/$startup_file" ]] ||
        die "missing legacy PIE startup file: $legacy_start_dir/$startup_file"
done
compiler_crtbegin="$("${CROSS}g++" -print-file-name=crtbeginS.o)"
compiler_crtend="$("${CROSS}g++" -print-file-name=crtendS.o)"
[[ -f "$compiler_crtbegin" ]] || die "missing compiler startup file: $compiler_crtbegin"
[[ -f "$compiler_crtend" ]] || die "missing compiler startup file: $compiler_crtend"

if [[ -z "${READELF:-}" ]]; then
    if command -v "${CROSS}readelf" >/dev/null; then
        READELF="${CROSS}readelf"
    else
        READELF=readelf
    fi
fi
command -v "$READELF" >/dev/null || die "missing readelf command: $READELF"

declare -a runtime_dirs=()
if [[ -n "$RUNTIME_LIBDIR" ]]; then
    IFS=: read -r -a runtime_dirs <<<"$RUNTIME_LIBDIR"
else
    runtime_dirs=(
        "$LEGACY_CXX_ROOT/lib/arm-linux-gnueabihf"
        "$SYSROOT/runtime"
        "$SYSROOT/lib/arm-linux-gnueabihf"
        "$SYSROOT/usr/lib/arm-linux-gnueabihf"
        "$SYSROOT/lib"
        "$SYSROOT/usr/lib"
    )
fi

for runtime_dir in "${runtime_dirs[@]}"; do
    [[ -d "$runtime_dir" ]] || continue
    break
done
[[ -n "${runtime_dir:-}" && -d "$runtime_dir" ]] ||
    die "no runtime library directory found; set RUNTIME_LIBDIR"

needed_libraries() {
    "$READELF" -d "$1" |
        awk '/\(NEEDED\)/ { gsub(/\[|\]/, "", $NF); print $NF }'
}

is_baseline_library() {
    case $1 in
        ld-linux-armhf.so.3|libc.so.6|libdl.so.2|libm.so.6|libpthread.so.0|librt.so.1)
            return 0
            ;;
    esac
    return 1
}

resolve_runtime_library() {
    local library=$1
    local runtime_dir

    for runtime_dir in "${runtime_dirs[@]}"; do
        [[ -d "$runtime_dir" && -e "$runtime_dir/$library" ]] || continue
        readlink -f "$runtime_dir/$library"
        return 0
    done

    return 1
}

validate_armhf_elf() {
    local artifact=$1
    local header

    header="$("$READELF" -h "$artifact")"
    grep -Eq 'Class:[[:space:]]+ELF32' <<<"$header" ||
        die "not an ELF32 artifact: $artifact"
    grep -Eq 'Machine:[[:space:]]+ARM' <<<"$header" ||
        die "not an ARM artifact: $artifact"
    grep -Eq 'Flags:.*hard-float ABI' <<<"$header" ||
        die "not an ARM hard-float artifact: $artifact"
}

stage_dependency_closure() {
    local artifact library source destination
    local -a queue=("$OUTPUT_DIR/rednukem")
    local -A inspected=()

    while [[ ${#queue[@]} -gt 0 ]]; do
        artifact=${queue[0]}
        queue=("${queue[@]:1}")

        [[ -n "${inspected[$artifact]:-}" ]] && continue
        inspected[$artifact]=1
        validate_armhf_elf "$artifact"

        while IFS= read -r library; do
            [[ -n "$library" ]] || continue
            if is_baseline_library "$library"; then
                continue
            fi

            destination="$OUTPUT_DIR/lib/$library"
            if [[ ! -e "$destination" ]]; then
                source="$(resolve_runtime_library "$library")" ||
                    die "cannot resolve target dependency $library; set RUNTIME_LIBDIR"
                cp -L "$source" "$destination"
            fi
            queue+=("$destination")
        done < <(needed_libraries "$artifact")
    done
}

validate_dependency_closure() {
    local artifact library
    local -a queue=("$OUTPUT_DIR/rednukem")
    local -A inspected=()

    while [[ ${#queue[@]} -gt 0 ]]; do
        artifact=${queue[0]}
        queue=("${queue[@]:1}")

        [[ -n "${inspected[$artifact]:-}" ]] && continue
        inspected[$artifact]=1
        validate_armhf_elf "$artifact"

        while IFS= read -r library; do
            [[ -n "$library" ]] || continue
            if is_baseline_library "$library"; then
                continue
            fi

            [[ -f "$OUTPUT_DIR/lib/$library" ]] ||
                die "unstaged non-baseline dependency $library required by $artifact"
            queue+=("$OUTPUT_DIR/lib/$library")
        done < <(needed_libraries "$artifact")
    done
}

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
    targets=(rr)
fi

build_config="$BUILD_DIR/.gamestation-go-build-config"
build_signature="$(
    printf '%s\n' \
        "sysroot=$SYSROOT" \
        "legacy_sysroot=$LEGACY_SYSROOT" \
        "legacy_cxx_root=$LEGACY_CXX_ROOT" \
        "renderer=$GSG_RENDERER" \
        "cross=$CROSS" \
        "gcc=$("${CROSS}gcc" -dumpfullversion -dumpversion)" \
        "script=$(sha256sum "${BASH_SOURCE[0]}" | awk '{ print $1 }')"
)"
existing_signature=
if [[ -f "$build_config" ]]; then
    existing_signature="$(cat "$build_config")"
fi
if [[ -d "$BUILD_DIR" && "$existing_signature" != "$build_signature" ]]; then
    case $BUILD_DIR in
        /|"$root"|"$root/obj")
            die "refusing to remove unsafe build directory: $BUILD_DIR"
            ;;
    esac
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
printf '%s\n' "$build_signature" >"$build_config"

linker_overlay="$BUILD_DIR/gamestation-go-linker"
rm -rf "$linker_overlay"
mkdir -p "$linker_overlay"
for library in libc libdl libm libpthread librt; do
    linker_script="$LEGACY_SYSROOT/usr/lib/arm-linux-gnueabihf/$library.so"
    [[ -f "$linker_script" ]] || die "missing legacy linker script: $linker_script"
    if grep -q 'GNU ld script' "$linker_script"; then
        sed -E \
            -e "s#(^|[[:space:](])/lib/arm-linux-gnueabihf/#\\1$LEGACY_SYSROOT/lib/arm-linux-gnueabihf/#g" \
            -e "s#(^|[[:space:](])/usr/lib/arm-linux-gnueabihf/#\\1$LEGACY_SYSROOT/usr/lib/arm-linux-gnueabihf/#g" \
            "$linker_script" >"$linker_overlay/$library.so"
    else
        ln -s "$linker_script" "$linker_overlay/$library.so"
    fi
done
ln -s "$SYSROOT/runtime/libatomic.so.1" "$linker_overlay/libatomic.so"

target_flags=(
    "--sysroot=$LEGACY_SYSROOT"
    -march=armv7-a
    -mfloat-abi=hard
    -mfpu=neon
    -fPIE
    # SDK headers (SDL 2.28.5 etc.) must precede the legacy sysroot: the legacy
    # tree carries SDL 2.0.5 headers that would otherwise shadow them, and a
    # directory given via both -I and -isystem keeps its -isystem position.
    "-isystem$SYSROOT/usr/include"
    "-isystem$LEGACY_SYSROOT/usr/include"
    "-isystem$LEGACY_SYSROOT/usr/include/arm-linux-gnueabihf"
    "-I$SYSROOT/usr/include/SDL2"
    -DREDNUKEM_GAMESTATION_GO
)
target_cxx_flags=(
    "--sysroot=$LEGACY_SYSROOT"
    -march=armv7-a
    -mfloat-abi=hard
    -mfpu=neon
    -fPIE
    -nostdinc++
    "-isystem$LEGACY_CXX_ROOT/include/c++/8"
    "-isystem$LEGACY_CXX_ROOT/include/arm-linux-gnueabihf/c++/8"
    "-isystem$LEGACY_CXX_ROOT/include/c++/8/backward"
    "-isystem$SYSROOT/usr/include"
    "-isystem$LEGACY_SYSROOT/usr/include"
    "-isystem$LEGACY_SYSROOT/usr/include/arm-linux-gnueabihf"
    "-I$SYSROOT/usr/include/SDL2"
    -DREDNUKEM_GAMESTATION_GO
)
target_ldflags=(
    "--sysroot=$LEGACY_SYSROOT"
    -pie
    -nodefaultlibs
    -Wl,--dynamic-linker=/lib/ld-linux-armhf.so.3
    -Wl,-z,max-page-size=65536
    "-L$linker_overlay"
    "-L$LEGACY_CXX_ROOT/lib/arm-linux-gnueabihf"
    "-L$SYSROOT/runtime"
    "-L$SYSROOT/usr/lib/arm-linux-gnueabihf"
    "-L$LEGACY_SYSROOT/lib/arm-linux-gnueabihf"
    "-Wl,-rpath-link,$SYSROOT/runtime"
    "-Wl,-rpath-link,$SYSROOT/usr/lib/arm-linux-gnueabihf"
    -Wl,--no-as-needed
    -Wl,-l:libstdc++.so.6
    -Wl,-l:libgcc_s.so.1
    -Wl,-l:libatomic.so.1
    -Wl,-l:libdl.so.2
    -Wl,-l:libpthread.so.0
    -Wl,-l:librt.so.1
    -Wl,-l:libm.so.6
    -Wl,-l:libc.so.6
    -Wl,-l:ld-linux-armhf.so.3
)
target_startfiles=(
    -nostartfiles
    "$legacy_start_dir/Scrt1.o"
    "$legacy_start_dir/crti.o"
    "$compiler_crtbegin"
)
target_endfiles=(
    "$legacy_start_dir/libc_nonshared.a"
    "$compiler_crtend"
    "$legacy_start_dir/crtn.o"
)

make -C "$root" \
    PLATFORM=LINUX \
    ARCH=armv7l \
    CROSS="$CROSS" \
    SDLCONFIG=false \
    HAVE_GTK2=0 \
    STARTUP_WINDOW=0 \
    USE_OPENGL="$use_opengl" \
    POLYMER=0 \
    USE_LIBVPX=0 \
    LTO=0 \
    obj="$BUILD_DIR" \
    "EXTRA_STARTFILES=${target_startfiles[*]}" \
    "EXTRA_LIBS=${target_endfiles[*]}" \
    "CFLAGS=${target_flags[*]} $TARGET_CFLAGS" \
    "CXXFLAGS=${target_cxx_flags[*]} $TARGET_CFLAGS" \
    "LDFLAGS=${target_ldflags[*]} $TARGET_LDFLAGS" \
    "${targets[@]}"

if [[ " ${targets[*]} " != *" rr "* ]]; then
    exit 0
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/rednukem" "$OUTPUT_DIR/run-rednukem.sh" "$OUTPUT_DIR/gamecontrollerdb.txt"
rm -rf "$OUTPUT_DIR/lib"
mkdir -p "$OUTPUT_DIR/lib"

cp "$root/rednukem" "$OUTPUT_DIR/rednukem"
cp "$root/platform/run-rednukem.sh" "$OUTPUT_DIR/run-rednukem.sh"
cp "$root/platform/gamestation-go-gamecontrollerdb.txt" "$OUTPUT_DIR/gamecontrollerdb.txt"
# License texts are optional in this tree; don't abort staging without them.
for license_text in buildlic.txt gpl-2.0.txt; do
    if [[ -f "$root/package/common/$license_text" ]]; then
        cp "$root/package/common/$license_text" "$OUTPUT_DIR/$license_text"
        chmod 644 "$OUTPUT_DIR/$license_text"
    fi
done
chmod 755 "$OUTPUT_DIR/rednukem" "$OUTPUT_DIR/run-rednukem.sh"
chmod 644 "$OUTPUT_DIR/gamecontrollerdb.txt"

stage_dependency_closure
validate_dependency_closure

header="$("$READELF" -h "$OUTPUT_DIR/rednukem")"
grep -Eq 'Type:[[:space:]]+DYN' <<<"$header" ||
    die "rednukem is not a PIE executable"
"$READELF" -l "$OUTPUT_DIR/rednukem" |
    grep -Fq 'Requesting program interpreter: /lib/ld-linux-armhf.so.3' ||
    die "rednukem does not use /lib/ld-linux-armhf.so.3"
load_alignments="$("$READELF" -lW "$OUTPUT_DIR/rednukem" |
    awk '$1 == "LOAD" { print $NF }')"
[[ -n "$load_alignments" ]] ||
    die "rednukem does not contain a loadable ELF segment"
grep -Fxqv '0x10000' <<<"$load_alignments" &&
    die "rednukem does not use 64 KiB load alignment"
attributes="$("$READELF" -A "$OUTPUT_DIR/rednukem")"
grep -Fq 'Tag_CPU_arch: v7' <<<"$attributes" ||
    die "rednukem is not built for ARMv7"
grep -Fq 'Tag_Advanced_SIMD_arch: NEONv1' <<<"$attributes" ||
    die "rednukem does not enable NEON"
grep -Fq 'Tag_ABI_VFP_args: VFP registers' <<<"$attributes" ||
    die "rednukem does not use the ARM hard-float ABI"

if [[ "$GSG_RENDERER" == dn64-gl ]]; then
    dynamic_symbols="$("$READELF" --dyn-syms -W "$OUTPUT_DIR/rednukem")"
    grep -Fq 'SDL_GL_CreateContext' <<<"$dynamic_symbols" ||
        die "dn64-gl package does not contain SDL OpenGL support"
fi

printf 'Built and validated %s\n' "$OUTPUT_DIR/rednukem"
