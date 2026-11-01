# Сборочный образ tachyon-proxy: Flutter + Android SDK/NDK + Rust с Android-таргетами.
#
# Один образ на все задачи:
#   * libtachyon.so  — кросс-компиляция core-ffi (JNI) из tachyon-core 0.2.6;
#   * APK             — сборка Flutter-приложения.
#
# Базовый образ cirruslabs/flutter содержит Flutter SDK, JDK 21 и Android SDK с
# cmdline-tools и лицензиями, поэтому NDK ставится через sdkmanager, а Rust —
# через rustup. CARGO_HOME/RUSTUP_HOME заданы явно: установщик rustup по
# умолчанию кладёт бинарники в $HOME/.cargo, а PATH здесь указывает на
# /usr/local/cargo.
FROM ghcr.io/cirruslabs/flutter:stable

ENV ANDROID_SDK_ROOT=/opt/android-sdk-linux
ENV ANDROID_HOME=/opt/android-sdk-linux
ENV NDK_VERSION=27.0.12077973
ENV NDK_HOME=/opt/android-sdk-linux/ndk/27.0.12077973
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:${PATH}

# NDK нужен линковщику Rust для Android-таргетов; платформа 35 и build-tools —
# для сборки APK.
RUN yes | sdkmanager --licenses > /dev/null 2>&1 || true
RUN sdkmanager --install \
        "ndk;${NDK_VERSION}" \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0" \
    && rm -rf /opt/android-sdk-linux/ndk/*/sources

# Rust с Android-таргетами: 64-битный ARM (реальные телефоны), 32-битный ARM
# (старые устройства) и x86_64 (эмулятор).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable \
    && rustc --version \
    && rustup target add \
        aarch64-linux-android \
        armv7-linux-androideabi \
        x86_64-linux-android

WORKDIR /src
CMD ["bash"]
