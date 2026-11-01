param(
    [switch]$Native,
    [switch]$AllAbis,
    [switch]$FullLto,
    [switch]$SkipApk,
    [switch]$Install,
    [string]$Device = "WG8DDUOZZXCQJ7TS"
)

$ErrorActionPreference = "Stop"

$env:JAVA_HOME = "C:\Users\Dushnilin\jdk-21"
$env:ANDROID_HOME = "C:\Users\Dushnilin\AppData\Local\Android\Sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_NDK_HOME = "$env:ANDROID_HOME\ndk\27.0.12077973"
$env:PATH = "$env:JAVA_HOME\bin;C:\Users\Dushnilin\flutter\bin;$env:ANDROID_HOME\platform-tools;$env:USERPROFILE\.cargo\bin;$env:PATH"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

if ($Native) {
    Write-Host "=== Нативная сборка libtachyon.so на Windows ===" -ForegroundColor Cyan
    $coreSrc = "G:\tachyon-core"
    $buildDir = "$repoRoot\native\core-ffi"
    $outDir = "$repoRoot\android\app\src\main\jniLibs"
    $workDir = "$buildDir\.work_win"
    $targetDir = "$repoRoot\.cache\cargo-win"

    New-Item -ItemType Directory -Force -Path "$workDir\core-ffi" | Out-Null
    robocopy "$coreSrc\crates" "$workDir\crates" /MIR /XO /NFL /NDL /NJH /NJS /NP | Out-Null
    robocopy "$coreSrc\vendor" "$workDir\vendor" /MIR /XO /NFL /NDL /NJH /NJS /NP | Out-Null
    robocopy "$buildDir\src" "$workDir\core-ffi\src" /MIR /XO /NFL /NDL /NJH /NJS /NP | Out-Null
    if (-not (Test-Path "$workDir\core-ffi\Cargo.toml") -or (Get-Item "$buildDir\Cargo.toml").LastWriteTime -gt (Get-Item "$workDir\core-ffi\Cargo.toml").LastWriteTime) {
        Copy-Item -Force "$buildDir\Cargo.toml" "$workDir\core-ffi\Cargo.toml"
    }
    if (-not (Test-Path "$workDir\Cargo.lock") -or (Get-Item "$coreSrc\Cargo.lock").LastWriteTime -gt (Get-Item "$workDir\Cargo.lock").LastWriteTime) {
        Copy-Item -Force "$coreSrc\Cargo.lock" "$workDir\Cargo.lock"
    }
    if (-not (Test-Path "$workDir\Cargo.toml") -or (Get-Item "$coreSrc\Cargo.toml").LastWriteTime -gt (Get-Item "$workDir\Cargo.toml").LastWriteTime) {
        $cargoToml = Get-Content "$coreSrc\Cargo.toml" -Raw -Encoding UTF8
        if ($cargoToml -notmatch '"core-ffi"') {
            $cargoToml = $cargoToml.Replace("members = [`n", "members = [`n    `"core-ffi`",`n")
            $cargoToml = $cargoToml.Replace("members = [`r`n", "members = [`r`n    `"core-ffi`",`r`n")
        }
        $cargoToml = $cargoToml.Replace('panic = "abort"', 'panic = "unwind"')
        [System.IO.File]::WriteAllText("$workDir\Cargo.toml", $cargoToml, (New-Object System.Text.UTF8Encoding($false)))
    }

    $ndkBin = "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin"
    $ar = "$ndkBin\llvm-ar.exe"

    function Build-RustTarget($triple, $abi, $cc, $extraFlags) {
        $envTriple = $triple.Replace("-", "_")
        $upper = $envTriple.ToUpper()
        [Environment]::SetEnvironmentVariable("CARGO_TARGET_${upper}_LINKER", $cc, "Process")
        [Environment]::SetEnvironmentVariable("CARGO_TARGET_${upper}_AR", $ar, "Process")
        [Environment]::SetEnvironmentVariable("CC_${envTriple}", $cc, "Process")
        [Environment]::SetEnvironmentVariable("AR_${envTriple}", $ar, "Process")
        $env:RUSTFLAGS = "$extraFlags -C link-arg=-Wl,-z,max-page-size=16384".Trim()
        if (-not $FullLto) {
            $env:CARGO_PROFILE_RELEASE_LTO = "off"
            $env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16"
        }

        Write-Host " -> cargo build --release --target $triple ($abi)" -ForegroundColor Yellow
        cargo.exe build --release --target $triple -p core-ffi `
            --manifest-path "$workDir\Cargo.toml" `
            --target-dir $targetDir
        if ($LASTEXITCODE -ne 0) { throw "Cargo build failed for $triple" }

        New-Item -ItemType Directory -Force -Path "$outDir\$abi" | Out-Null
        Copy-Item -Force "$targetDir\$triple\release\libtachyon.so" "$outDir\$abi\libtachyon.so"
    }

    Build-RustTarget "aarch64-linux-android" "arm64-v8a" "$ndkBin\aarch64-linux-android26-clang.cmd" "--cfg aes_armv8 --cfg polyval_armv8 --cfg chacha20_force_neon"
    if ($AllAbis) {
        Build-RustTarget "armv7-linux-androideabi" "armeabi-v7a" "$ndkBin\armv7a-linux-androideabi26-clang.cmd" ""
        Build-RustTarget "x86_64-linux-android" "x86_64" "$ndkBin\x86_64-linux-android26-clang.cmd" "-C target-cpu=x86-64"
    }
}

if (-not $SkipApk) {
    Write-Host "=== Сборка APK через локальный Flutter + Gradle ===" -ForegroundColor Cyan
    if (-not (Test-Path "$repoRoot\.dart_tool\package_config.json")) {
        flutter.bat pub get
    }
    flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
    if ($LASTEXITCODE -ne 0) { throw "Flutter APK build failed" }
}

if ($Install) {
    $apkPath = "$repoRoot\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
    Write-Host "=== Установка $apkPath на $Device ===" -ForegroundColor Green
    adb.exe -s $Device install -r $apkPath
}
