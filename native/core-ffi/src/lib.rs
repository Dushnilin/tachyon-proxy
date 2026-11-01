//! JNI surface for embedding tachyon-core in the Android VpnService process.
//!
//! One box per process: the runtime carries process-global DNS, clash and log
//! state, so `start` after `stop` is a restart and never a second instance.
//!
//! The config travels as sing-box JSON, validated as written. The pieces the
//! platform owns are injected *after* `check` (a validated config must not
//! carry them вЂ” sing-box has no such fields):
//!
//! * `fd` on the tun inbound вЂ” the descriptor `VpnService.establish()` hands
//!   over; `tun.rs` reads packets from it instead of opening `/dev/net/tun`.
//! * `protect_path` on every outbound and endpoint вЂ” the unix socket where
//!   the Kotlin side answers with `VpnService.protect(fd)`, so core sockets
//!   bypass the VPN instead of looping back into the tun.
//! * `log.output` вЂ” the file the app tails for its Logs screen.
//!
//! An `ntp` section is *removed* on Android instead: core's NTP dials a bare
//! `UdpSocket` with no protect hook, and under the VPN every datagram would be
//! routed back into our own tun (each hop opening a fresh socket вЂ” an
//! infinite loop). Re-add once core's NTP honours `protect_path`.
//!
//! Kotlin class: `org.tachyon.vpn.TachyonCore`, `System.loadLibrary("tachyon")`.

#[cfg(unix)]
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex, PoisonError};

#[cfg(unix)]
use jni::objects::JValue;
use jni::objects::{JObject, JString};
#[cfg(unix)]
use jni::{jni_sig, jni_str};
use jni::sys::{jint, jstring};
use jni::{Env, EnvUnowned};
use serde_json::Value;

/// The single running box: its runtime and the instance to shut down.
struct Core {
    rt: tokio::runtime::Runtime,
    inst: Option<core_runtime::BoxInstance>,
}

static CORE: LazyLock<Mutex<Option<Core>>> = LazyLock::new(|| Mutex::new(None));
static LAST_ERROR: Mutex<String> = Mutex::new(String::new());

fn set_last_error(msg: String) {
    *LAST_ERROR.lock().unwrap_or_else(PoisonError::into_inner) = msg;
}

fn last_error() -> String {
    LAST_ERROR
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

/// `Ok(warnings)` only when the document as written passes `sing-box check`.
fn validate(json: &str) -> Result<Vec<String>, String> {
    core_config::check_str_warnings(json)
}

/// Insert what the platform owns into an already-validated config.
///
/// `tun_fd < 0` means "no tun inbound this time" (proxy-only start); the
/// inbound then keeps its own bind and fails loudly on Android rather than
/// silently opening `/dev/net/tun`, which an app can never do.
fn inject(
    root: &mut Value,
    tun_fd: i32,
    protect_path: &str,
    log_path: &str,
    strip_ntp: bool,
) {
    if let Ok(Some(expanded)) = core_config::subscription::expand(root) {
        *root = expanded;
    }
    let Some(obj) = root.as_object_mut() else {
        return;
    };
    if tun_fd >= 0
        && let Some(inbounds) = obj.get_mut("inbounds").and_then(Value::as_array_mut)
    {
        for inbound in inbounds.iter_mut() {
            if inbound.get("type").and_then(Value::as_str) == Some("tun")
                && let Some(inbound) = inbound.as_object_mut()
            {
                inbound.insert("fd".to_owned(), Value::from(tun_fd));
            }
        }
    }
    if !protect_path.is_empty() {
        // `validate` has already run, so these keys never face the schema.
        for section in ["outbounds", "endpoints"] {
            if let Some(entries) = obj.get_mut(section).and_then(Value::as_array_mut) {
                for entry in entries.iter_mut() {
                    if let Some(entry) = entry.as_object_mut()
                        && !entry.contains_key("protect_path")
                    {
                        entry.insert(
                            "protect_path".to_owned(),
                            Value::String(protect_path.to_owned()),
                        );
                    }
                }
            }
        }
    }
    if strip_ntp {
        obj.remove("ntp");
    }
    if !log_path.is_empty()
        && let Some(log) = obj
            .get_mut("log")
            .and_then(Value::as_object_mut)
    {
        log.insert("output".to_owned(), Value::String(log_path.to_owned()));
    }
}

/// Bring the box up. Returns the notes `start` wants in the log: `check`
/// warnings plus config surgery performed for this platform.
fn start_box(
    json: &str,
    tun_fd: i32,
    protect_path: &str,
    log_path: &str,
) -> Result<Vec<String>, String> {
    let mut notes = validate(json)?
        .into_iter()
        .map(|w| format!("check: {w}"))
        .collect::<Vec<_>>();
    let mut root: Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let strip_ntp = cfg!(target_os = "android");
    let had_ntp = root.get("ntp").is_some();
    inject(&mut root, tun_fd, protect_path, log_path, strip_ntp);
    if strip_ntp && had_ntp {
        notes.push(
            "ntp: section removed on Android - core NTP has no protect_path, \
             bare datagrams would loop back into the tun"
                .to_owned(),
        );
    }

    // The core writes its cache file and the rule-set cache relative to the
    // working directory. On Android the process starts in the app's root
    // directory, which is read-only - move next to the log file, which the
    // app owns.
    if !log_path.is_empty() {
        if let Some(dir) = std::path::Path::new(log_path).parent() {
            if dir.is_dir() {
                if let Err(err) = std::env::set_current_dir(dir) {
                    notes.push(format!("work dir: cannot use {}: {err}", dir.display()));
                }
            }
        }
    }

    let mut guard = CORE.lock().unwrap_or_else(PoisonError::into_inner);
    if guard.is_some() {
        return Err("core already running (stop first)".to_owned());
    }
    // Same shape as `core-cli`'s runtime: hardware-derived workers, one
    // blocking pool sized so a slow DNS probe never parks the packet path.
    let hw = core_runtime::hardware::HardwareProfile::detect();
    let rt = if hw.workers == 1 {
        tokio::runtime::Builder::new_current_thread()
            .event_interval(31)
            .max_blocking_threads(hw.max_blocking_threads)
            .enable_all()
            .build()
    } else {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(hw.workers)
            .event_interval(31)
            .max_blocking_threads(hw.max_blocking_threads)
            .enable_all()
            .build()
    }
    .map_err(|e| format!("runtime: {e}"))?;

    let result = rt
        .block_on(core_runtime::start(&root))
        .map_err(|e| format!("{e:#}"));
    match result {
        Ok(inst) => {
            // `logging::init` has run inside `start`, so notes land in the log.
            for note in &notes {
                core_runtime::logging::info(format_args!("{note}"));
            }
            *guard = Some(Core {
                rt,
                inst: Some(inst),
            });
            Ok(notes)
        }
        Err(err) => {
            // Nothing is spawned on failure (start's TaskGuard), so the runtime
            // goes away with the error and the next start gets a clean slate.
            rt.shutdown_timeout(std::time::Duration::from_millis(250));
            Err(err)
        }
    }
}

/// Drain the box: abort listeners, wait for the tasks, then the runtime.
fn stop_box() -> Result<(), String> {
    let mut guard = CORE.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(mut core) = guard.take() else {
        return Ok(());
    };
    if let Some(mut inst) = core.inst.take() {
        core.rt.block_on(inst.shutdown_wait());
    }
    core.rt.shutdown_timeout(std::time::Duration::from_millis(250));
    Ok(())
}

// --- JNI entry points. Signatures mirror org.tachyon.vpn.TachyonCore. ---
//
// `with_env` upgrades the FFI-safe `EnvUnowned`, runs the body under
// `catch_unwind` and lets the policy map failures to a Java exception; every
// application-level failure is converted to an error code + `lastError()`
// instead, so the service decides what the UI shows.

fn read_string(env: &Env, value: &JString) -> Result<String, jni::errors::Error> {
    value.try_to_string(env)
}

fn make_jstring(env: &mut Env, value: &str) -> Result<jstring, jni::errors::Error> {
    Ok(JString::from_str(env, value)?.into_raw())
}

/// `start(config: String, tunFd: Int, protectPath: String, logPath: String): Int`
/// вЂ” 0 on success, -1 with the reason in `lastError()`. Blocking: call it off
/// the main thread, never concurrently with `stop`.
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_start<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
    config: JString<'caller>,
    tun_fd: jint,
    protect_path: JString<'caller>,
    log_path: JString<'caller>,
) -> jint {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jint> {
            let json = read_string(env, &config)?;
            let protect_path = read_string(env, &protect_path)?;
            let log_path = read_string(env, &log_path)?;
            match start_box(&json, tun_fd, &protect_path, &log_path) {
                Ok(_) => Ok(0),
                Err(err) => {
                    set_last_error(err);
                    Ok(-1)
                }
            }
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `stop(): Int` вЂ” drains the box and waits for a clean shutdown. Blocking:
/// call it off the main thread.
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_stop<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
) -> jint {
    unowned_env
        .with_env(|_env| -> jni::errors::Result<jint> {
            match stop_box() {
                Ok(()) => Ok(0),
                Err(err) => {
                    set_last_error(err);
                    Ok(-1)
                }
            }
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `lastError(): String?` вЂ” detail of the last non-zero result (null only if
/// the JVM could not allocate the string).
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_lastError<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> { make_jstring(env, &last_error()) })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `version(): String?`
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_version<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            make_jstring(env, env!("CARGO_PKG_VERSION"))
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `stats(): String?` вЂ” СЃС‡С‘С‚С‡РёРєРё С‚СЂР°С„РёРєР° Рё СЃРѕСЃС‚РѕСЏРЅРёРµ.
///
/// Р’РѕР·РІСЂР°С‰Р°РµС‚ JSON: `{"running":true,"up":N,"down":N,"connections":M}`.
/// РЇРґСЂРѕ СЃС‡РёС‚Р°РµС‚ Р±Р°Р№С‚С‹ РїРѕ РІСЃРµРј СЃРѕРµРґРёРЅРµРЅРёСЏРј СЃ РјРѕРјРµРЅС‚Р° Р·Р°РїСѓСЃРєР°, РїРѕСЌС‚РѕРјСѓ UI
/// РїРѕРєР°Р·С‹РІР°РµС‚ РёС… РЅР°РїСЂСЏРјСѓСЋ, Р±РµР· СЃРѕР±СЃС‚РІРµРЅРЅРѕРіРѕ СѓС‡С‘С‚Р°.
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_nativeStats<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            let guard = CORE.lock().unwrap_or_else(PoisonError::into_inner);
            let running = guard.is_some();
            drop(guard);
            let (up, down) = core_runtime::clash_state::traffic_totals();
            let connections = core_runtime::clash_state::snapshot().0.len();
            let answer = format!(
                "{{\"running\":{},\"up\":{},\"down\":{},\"connections\":{}}}",
                running, up, down, connections
            );
            make_jstring(env, &answer)
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `check(config: String): String?` - validate a config without running it.
///
/// The answer is a JSON document: `{"ok":true,"warnings":[...]}` when the
/// document passes the engine's schema and initializes, `{"ok":false,
/// "error":"..."}` otherwise. The app gates every import on this call, so a
/// config that reaches the core is a config the core accepted.
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_check<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
    config: JString<'caller>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            let json = read_string(env, &config)?;
            let answer = match validate(&json) {
                Ok(warnings) => {
                    let list = warnings
                        .iter()
                        .map(|w| {
                            serde_json::to_string(w).unwrap_or_else(|_| "\"\"".to_owned())
                        })
                        .collect::<Vec<_>>()
                        .join(",");
                    format!("{{\"ok\":true,\"warnings\":[{list}]}}")
                }
                Err(err) => format!(
                    "{{\"ok\":false,\"error\":{}}}",
                    serde_json::to_string(&err).unwrap_or_else(|_| "\"unknown error\"".to_owned())
                ),
            };
            make_jstring(env, &answer)
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

// --- protect helper --------------------------------------------------------
//
// The core dials through `protect_path` (`core-runtime/src/protect.rs`):
// connect, hand the socket over with SCM_RIGHTS, wait for one byte. This side
// answers. The loop runs on a Kotlin thread that called `protectLoop`, so it
// is still attached to the JVM and the `VpnService.protect(fd)` upcall needs
// no attach machinery; a false answer hangs up without a byte, which the
// client reads as an error.

/// The listener bound by `protectOpen`, tagged with the generation that
/// retires it.
#[cfg(unix)]
static PROTECT: Mutex<Option<(u64, std::os::unix::net::UnixListener)>> = Mutex::new(None);
/// Bumped by every `protectOpen`/`protectClose`: closing another thread's
/// blocked `accept` is not portable, so the loop polls this instead.
#[cfg(unix)]
static PROTECT_GEN: AtomicU64 = AtomicU64::new(0);

#[cfg(unix)]
fn open_protect(path: &str) -> jint {
    use std::os::unix::net::UnixListener;
    // A crashed run leaves the socket file behind; the path is ours alone.
    let _ = std::fs::remove_file(path);
    match UnixListener::bind(path) {
        Ok(listener) => {
            let generation = PROTECT_GEN.fetch_add(1, Ordering::SeqCst) + 1;
            *PROTECT.lock().unwrap_or_else(PoisonError::into_inner) = Some((generation, listener));
            0
        }
        Err(err) => {
            set_last_error(format!("protect open {path}: {err}"));
            -1
        }
    }
}

#[cfg(not(unix))]
fn open_protect(_path: &str) -> jint {
    set_last_error("protect: unix only".to_owned());
    -1
}

/// Serve the helper socket until the generation moves on. `decide` runs once
/// per received descriptor and decides the ack; refusal (or a malformed
/// message) drops the stream, which is how the client learns the helper said
/// no. The descriptor arrives as a dup вЂ” closed here either way, the dialer
/// keeps its original.
#[cfg(unix)]
fn serve_loop(
    listener: std::os::unix::net::UnixListener,
    my_gen: u64,
    mut decide: impl FnMut(std::os::fd::RawFd) -> bool,
) -> usize {
    use std::io::Write as _;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};

    let _ = listener.set_nonblocking(true);
    let mut acked = 0usize;
    while PROTECT_GEN.load(Ordering::SeqCst) == my_gen {
        match listener.accept() {
            Ok((mut stream, _)) => {
                if let Ok(fd) = core_runtime::protect::recv_fd(&stream) {
                    let dup = unsafe { OwnedFd::from_raw_fd(fd) };
                    let accepted = decide(dup.as_raw_fd());
                    drop(dup);
                    if accepted {
                        let _ = stream.write_all(&[1u8]);
                        acked += 1;
                    }
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(_) => break,
        }
    }
    acked
}

#[cfg(unix)]
fn serve(env: &mut Env, service: &JObject) -> jint {
    let Some((my_gen, listener)) = PROTECT
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take()
    else {
        set_last_error("protect: no listener (protectOpen first)".to_owned());
        return -1;
    };
    serve_loop(listener, my_gen, |fd| {
        let res = env
            .call_method(
                service,
                jni_str!("protect"),
                jni_sig!("(I)Z"),
                &[JValue::Int(fd)],
            )
            .and_then(|value| value.z());
        match res {
            Ok(ok) => ok,
            Err(err) => {
                let _ = env.exception_clear();
                core_runtime::logging::warn(format_args!("protect({fd}) jni call failed: {err}"));
                false
            }
        }
    });
    0
}

#[cfg(not(unix))]
fn serve(_env: &mut Env, _service: &JObject) -> jint {
    set_last_error("protect: unix only".to_owned());
    -1
}

/// Retire the current generation: any running loop leaves within one poll
/// tick and the listener drops with it.
fn close_protect() -> jint {
    #[cfg(unix)]
    {
        PROTECT_GEN.fetch_add(1, Ordering::SeqCst);
        PROTECT
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
    }
    0
}

/// `protectOpen(path: String): Int` вЂ” bind the socket `protect_path` clients
/// connect to. Call before `start` so the first dial already finds a
/// listener; `protectLoop` serves it from its own thread.
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_protectOpen<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
    path: JString<'caller>,
) -> jint {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jint> { Ok(open_protect(&read_string(env, &path)?)) })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `protectLoop(service: TachyonVpnService): Int` вЂ” blocking accept loop on
/// the calling thread; upcalls `service.protectFd(fd)`. Returns -1 with
/// `lastError()` if `protectOpen` did not run; otherwise runs until
/// `protectClose`.
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_protectLoop<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
    service: JObject<'caller>,
) -> jint {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jint> { Ok(serve(env, &service)) })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `protectClose(): Int` вЂ” stop serving; the loop thread returns on its own.
#[unsafe(no_mangle)]
pub extern "system" fn Java_org_tachyon_vpn_TachyonCore_protectClose<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _this: JObject<'caller>,
) -> jint {
    unowned_env
        .with_env(|_env| -> jni::errors::Result<jint> { Ok(close_protect()) })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn inject_places_the_platform_pieces_without_touching_the_schema() {
        let mut root = json!({
            "log": {"level": "warn"},
            "ntp": {"enabled": true, "server": "pool.ntp.org"},
            "inbounds": [
                {"type": "mixed", "tag": "mixed-in"},
                {"type": "tun", "tag": "tun", "stack": "system"}
            ],
            "outbounds": [
                {"type": "direct", "tag": "direct", "protect_path": "/keep/me"},
                {"type": "shadowsocks", "tag": "ss"}
            ],
            "endpoints": [{"type": "wireguard", "tag": "wg"}]
        });
        inject(&mut root, 7, "/data/data/app/protect.sock", "/l/core.log", true);

        let obj = root.as_object().unwrap();
        let inbounds = obj["inbounds"].as_array().unwrap();
        assert!(inbounds[0].get("fd").is_none(), "fd lands on tun only");
        assert_eq!(inbounds[1]["fd"], 7, "tun inbound got the descriptor");
        let outbounds = obj["outbounds"].as_array().unwrap();
        assert_eq!(outbounds[0]["protect_path"], "/keep/me", "never overwrite");
        assert_eq!(
            outbounds[1]["protect_path"], "/data/data/app/protect.sock",
            "bare outbound gets protected"
        );
        assert_eq!(obj["endpoints"][0]["protect_path"], "/data/data/app/protect.sock");
        assert!(obj.get("ntp").is_none(), "strip_ntp removes the section");
        assert_eq!(obj["log"]["output"], "/l/core.log");
    }

    #[test]
    fn inject_keeps_ntp_when_not_stripping_and_leaves_it_alone() {
        let mut root = json!({"ntp": {"enabled": true, "server": "pool.ntp.org"}});
        inject(&mut root, -1, "/p.sock", "", false);

        let obj = root.as_object().unwrap();
        assert_eq!(obj["ntp"]["server"], "pool.ntp.org");
        assert!(
            obj["ntp"].get("protect_path").is_none(),
            "core NTP ignores the field; only stripping is honoured"
        );
        assert!(obj.get("inbounds").is_none(), "no tun_fd: nothing to inject");
    }

    #[test]
    fn check_rejects_what_the_app_would_ship_bad() {
        assert!(validate("{not json").is_err());
        assert!(validate(r#"{"futureSection":{}}"#).is_err());
        assert!(validate(r#"{"outbounds":[{"type":"direct"}]}"#).is_ok());
    }

    /// The wire the Kotlin helper must reproduce: real `protect()` client,
    /// real listener, first descriptor refused (reads as EOF), second acked,
    /// loop retires when the generation moves.
    #[cfg(unix)]
    #[test]
    fn protect_helper_answers_with_one_byte_only_when_accepted() {
        use std::os::fd::AsRawFd as _;
        use std::os::unix::net::UnixStream;
        use std::sync::atomic::{AtomicUsize, Ordering as _};

        static N: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "tachyon-protect-{}-{}.sock",
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        let path = path.to_str().unwrap();

        assert_eq!(open_protect(path), 0, "binds the helper socket");
        let (generation, listener) = PROTECT
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
            .expect("protectOpen stored its listener");

        let calls = std::sync::Arc::new(AtomicUsize::new(0));
        let calls_in_loop = calls.clone();
        let server = std::thread::spawn(move || {
            serve_loop(listener, generation, move |_| {
                // first descriptor refused, every later one acked
                calls_in_loop.fetch_add(1, Ordering::SeqCst) > 0
            })
        });

        let (mine, _peer) = UnixStream::pair().unwrap();
        assert!(
            core_runtime::protect::protect(path, mine.as_raw_fd()).is_err(),
            "a refused descriptor reads as a hang-up, not a stray byte"
        );
        let (mine, _peer) = UnixStream::pair().unwrap();
        core_runtime::protect::protect(path, mine.as_raw_fd())
            .expect("an accepted descriptor is acked with one byte");

        PROTECT_GEN.fetch_add(1, Ordering::SeqCst); // what protectClose does
        assert_eq!(server.join().unwrap(), 1, "one ack for two attempts");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(close_protect(), 0, "listener already taken: clean no-op");
        let _ = std::fs::remove_file(path);
    }
}

