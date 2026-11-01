#!/usr/bin/env bash
# Сборка libtachyon.so для трёх Android ABI из tachyon-core 0.2.6 + core-ffi.
#
# Запуск (из корня репозитория tachyon-proxy):
#   docker build -t tachyon-proxy-build -f docker/Dockerfile .
#   docker run --rm -v "$PWD:/src" -v "G:/tachyon-core:/core:ro" \
#       tachyon-proxy-build bash docker/build_native.sh
#
# core-ffi собирается как член workspace ядра (в копии, оригинал не трогаем):
# так применяются вендорные патчи h2/quinn/quinn-proto/smoltcp и совпадают
# версии зависимостей. Единственное отличие — panic = "unwind" вместо abort:
# паника в задаче соединения не должна убивать процесс приложения, а
# jni::with_env должен превращать её в Java-исключение.
set -euo pipefail

CORE_SRC="${CORE_SRC:-/core}"
BUILD_DIR="${BUILD_DIR:-/src/native/core-ffi}"
OUT_DIR="${OUT_DIR:-/src/android/app/src/main/jniLibs}"
# Кэш cargo на примонтированном томе: контейнер запускается с --rm, и без
# этого каждая пересборка начиналась бы с нуля.
CACHE_DIR="${CACHE_DIR:-/src/.cache/cargo}"

export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-sdk-linux/ndk/27.0.12077973}"
NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"

# API 26 = minSdk приложения.
CC_AARCH64="${NDK_TOOLCHAIN}/bin/aarch64-linux-android26-clang"
CC_ARMV7="${NDK_TOOLCHAIN}/bin/armv7a-linux-androideabi26-clang"
CC_X86_64="${NDK_TOOLCHAIN}/bin/x86_64-linux-android26-clang"
AR="${NDK_TOOLCHAIN}/bin/llvm-ar"

for tool in "${CC_AARCH64}" "${CC_ARMV7}" "${CC_X86_64}" "${AR}"; do
    if [[ ! -x "${tool}" ]]; then
        echo "NDK tool not found: ${tool}" >&2
        exit 1
    fi
done

# --- подготовка исходников ------------------------------------------------
WORK="${BUILD_DIR}/.work"
rm -rf "${WORK}"
mkdir -p "${WORK}/core-ffi"

cp "${CORE_SRC}/Cargo.toml" "${WORK}/Cargo.toml"
cp "${CORE_SRC}/Cargo.lock" "${WORK}/Cargo.lock"
cp -r "${CORE_SRC}/crates" "${WORK}/crates"
cp -r "${CORE_SRC}/vendor" "${WORK}/vendor"
cp -r "${BUILD_DIR}/src" "${WORK}/core-ffi/src"
cp "${BUILD_DIR}/Cargo.toml" "${WORK}/core-ffi/Cargo.toml"

# core-ffi — член workspace ядра: наследует версии и вендорные патчи.
python3 - "${WORK}/Cargo.toml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

if '"core-ffi"' not in text:
    text = text.replace(
        'members = [\n',
        'members = [\n    "core-ffi",\n',
        1,
    )

# Профиль ядра оптимизирован под размер и ставит panic = "abort". Для JNI
# нужен unwind: паника в задаче не должна убивать процесс приложения.
if 'panic = "abort"' in text:
    text = text.replace('panic = "abort"', 'panic = "unwind"', 1)

open(path, "w", encoding="utf-8").write(text)
PY

# --- сборка ---------------------------------------------------------------
build_target() {
    local triple="$1" abi="$2" cc="$3"
    # Имя переменной окружения cargo: точка/дефис заменяются на подчёркивание.
    local env_triple="${triple//-/_}"
    local upper="${env_triple^^}"
    local rustflags=()

    case "${triple}" in
        aarch64-linux-android)
            # Аппаратные AES/PMULL/NEON выбираются рантайм-детектором, поэтому
            # cfgs безопасны: устройство без AES уходит в программный путь.
            rustflags=(--cfg aes_armv8 --cfg polyval_armv8 --cfg chacha20_force_neon)
            ;;
        x86_64-linux-android)
            rustflags=(-C target-cpu=x86-64)
            ;;
    esac

    # Android 15+ требует выравнивания сегментов под 16 КБ страницы.
    rustflags+=(-C "link-arg=-Wl,-z,max-page-size=16384")

    echo "=== building ${triple} (${abi}) ==="
    env \
        "CARGO_TARGET_${upper}_LINKER=${cc}" \
        "CARGO_TARGET_${upper}_AR=${AR}" \
        "CC_${env_triple}=${cc}" \
        "AR_${env_triple}=${AR}" \
        "RUSTFLAGS=${rustflags[*]}" \
        cargo build --release --target "${triple}" -p core-ffi \
            --manifest-path "${WORK}/Cargo.toml" \
            --target-dir "${CACHE_DIR}"

    mkdir -p "${OUT_DIR}/${abi}"
    cp "${CACHE_DIR}/${triple}/release/libtachyon.so" "${OUT_DIR}/${abi}/libtachyon.so"
    ls -l "${OUT_DIR}/${abi}/libtachyon.so"
}

mkdir -p "${OUT_DIR}"
build_target aarch64-linux-android arm64-v8a "${CC_AARCH64}"
if [[ "${ONLY_ARM64:-0}" != "1" ]]; then
    build_target armv7-linux-androideabi armeabi-v7a "${CC_ARMV7}"
    build_target x86_64-linux-android x86_64 "${CC_X86_64}"
fi

echo "=== all ABIs built ==="
find "${OUT_DIR}" -name 'libtachyon.so' -printf '%p %s bytes\n'
