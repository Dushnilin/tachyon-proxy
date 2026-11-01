#!/usr/bin/env bash
# Сборка APK: Flutter-приложение с libtachyon.so из jniLibs.
#
# Нативная библиотека собирается отдельно (docker/build_native.sh) и кладётся
# в android/app/src/main/jniLibs — здесь она просто попадает в APK.
#
# Запуск (кэши подключаются наружу, иначе Gradle и pub качаются заново
# при каждом запуске):
#   docker build -t tachyon-proxy-build -f docker/Dockerfile .
#   docker run --rm -v "$PWD:/src" -v "$PWD/.cache/gradle:/root/.gradle" \
#       -v "$PWD/.cache/pub:/root/.pub-cache" -w /src \
#       tachyon-proxy-build bash docker/build_apk.sh
set -euo pipefail

APP_DIR="${APP_DIR:-/src}"
OUT_DIR="${OUT_DIR:-/src/build/app/outputs/flutter-apk}"

cd "${APP_DIR}"

# Стабильный debug-ключ: без закреплённого хранилища каждая сборка в новом
# контейнере подписывалась бы свежим ключом, и установка поверх старой версии
# падала бы с INSTALL_FAILED_UPDATE_INCOMPATIBLE.
mkdir -p /root/.android
if [ -f /src/.cache/debug.keystore ]; then
  cp /src/.cache/debug.keystore /root/.android/debug.keystore
  echo "=== debug.keystore восстановлен из .cache ==="
fi

echo "=== flutter pub get ==="
flutter pub get

echo "=== сборка release APK ==="
flutter build apk --release

echo "=== сборка split по ABI (быстрее ставится на устройство) ==="
flutter build apk --release --split-per-abi

# Сохраняем ключ для будущих сборок.
if [ -f /root/.android/debug.keystore ] && [ ! -f /src/.cache/debug.keystore ]; then
  mkdir -p /src/.cache
  cp /root/.android/debug.keystore /src/.cache/debug.keystore
fi

echo "=== готово ==="
find "${OUT_DIR}" -name '*.apk' -printf '%p %s bytes\n' 2>/dev/null || true
