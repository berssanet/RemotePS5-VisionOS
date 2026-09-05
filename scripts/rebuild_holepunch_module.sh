#!/bin/bash
# Rebuild remote/holepunch.c for visionOS and update libchiaki_full.a.
#
# Why: the curl inside libchiaki_full.a uses the mbedTLS backend with no CA bundle, so
# every PSN HTTPS/WebSocket request fails peer verification on visionOS. holepunch.c
# never sets CURLOPT_CAINFO, and the vendored source is read-only, so the object is
# recompiled with `curl_easy_init` redirected (compile flag, no source edit) to
# chiaki_visionos_curl_easy_init in VisionRemotePS5/Chiaki/ChiakiCore.c, which points
# curl at the cacert.pem bundled in the app.
#
# Prerequisites: scripts/build_jsonc_visionos.sh (json-c headers) and a miniupnpc
# header set (Homebrew: brew install miniupnpc). Same pattern as rebuild_video_modules.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
CHIAKI_DIR="$PROJECT_DIR/chiaki-ng"
LIB_PATH="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a"
HEADERS_DIR="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/Headers"
TEMP_DIR="$PROJECT_DIR/build-temp-holepunch"
JSONC_WORK_DIR="${JSONC_WORK_DIR:-/tmp/jsonc-visionos}"
JSONC_SRC="$(ls -d "$JSONC_WORK_DIR"/json-c-json-c-* | head -1)"
JSONC_BUILD="$JSONC_WORK_DIR/build-xros"
MINIUPNPC_INCLUDE="${MINIUPNPC_INCLUDE:-$(brew --prefix miniupnpc 2>/dev/null)/include}"

echo "=== Rebuilding holepunch module for visionOS ==="
SDK_PATH=$(xcrun --sdk xros --show-sdk-path)
CLANG=$(xcrun --sdk xros --find clang)
AR=$(xcrun --sdk xros --find ar)
LIBTOOL=$(xcrun --sdk xros --find libtool)

rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR/include/json-c"
cp "$JSONC_SRC"/*.h "$TEMP_DIR/include/json-c/"
cp "$JSONC_BUILD"/*.h "$TEMP_DIR/include/json-c/"

# Bash array: the project path may contain spaces.
CFLAGS=(-target arm64-apple-xros2.0
        -isysroot "$SDK_PATH"
        -I"$CHIAKI_DIR/lib/include"
        -I"$HEADERS_DIR"
        -I"$PROJECT_DIR/VisionRemotePS5/Chiaki"
        -I"$CHIAKI_DIR/third-party/curl/include"
        -I"$TEMP_DIR/include"
        -I"$MINIUPNPC_INCLUDE"
        -I"$PROJECT_DIR/mbedtls-src/include"
        -DCHIAKI_LIB_ENABLE_MBEDTLS=1
        -DCHIAKI_LIB_ENABLE_OPUS=1
        -Dcurl_easy_init=chiaki_visionos_curl_easy_init
        -O2
        -fPIC
        -Wall
        -Wno-unused-function)

# Work on a COPY of the vendored source (the chiaki-ng tree is read-only) and apply one
# upstream fix: if the push WebSocket thread fails to connect, chiaki_holepunch_session_create
# waits for SESSION_STATE_WS_OPEN forever (the loop ignores main_should_stop). The copy makes
# the thread flag the failure and the loop honour it, so the caller gets CHIAKI_ERR_CANCELED.
cp "$CHIAKI_DIR/lib/src/remote/holepunch.c" "$TEMP_DIR/holepunch.c"
cp "$CHIAKI_DIR/lib/src/remote/stun.h" "$TEMP_DIR/stun.h"
cp "$CHIAKI_DIR/lib/src/utils.h" "$TEMP_DIR/utils.h"
python3 - "$TEMP_DIR/holepunch.c" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old_loop = """    while (!(session->state & SESSION_STATE_WS_OPEN))
    {
        CHIAKI_LOGV(session->log, "chiaki_holepunch_session_create: Waiting for websocket to open...");"""
new_loop = """    while (!(session->state & SESSION_STATE_WS_OPEN) && !session->main_should_stop) /* visionOS: honour cancel */
    {
        CHIAKI_LOGV(session->log, "chiaki_holepunch_session_create: Waiting for websocket to open...");"""
assert s.count(old_loop) == 1, "wait loop anchor"
s = s.replace(old_loop, new_loop)
old_cleanup = """cleanup:
    curl_easy_cleanup(curl);
    session->ws_open = false;

    return NULL;
}"""
new_cleanup = """cleanup:
    if(!session->ws_open)
    {
        /* visionOS: the WebSocket never opened -> unblock chiaki_holepunch_session_create */
        chiaki_mutex_lock(&session->stop_mutex);
        session->main_should_stop = true;
        chiaki_mutex_unlock(&session->stop_mutex);
        chiaki_mutex_lock(&session->state_mutex);
        chiaki_cond_signal(&session->state_cond);
        chiaki_mutex_unlock(&session->state_mutex);
    }
    curl_easy_cleanup(curl);
    session->ws_open = false;

    return NULL;
}"""
assert s.count(old_cleanup) == 1, "ws cleanup anchor"
s = s.replace(old_cleanup, new_cleanup)
# A PS5 that just finished another Remote Play session can take a while to join (chiaki-ng #587).
old_timeout = "#define SESSION_START_TIMEOUT_SEC 30"
assert s.count(old_timeout) == 1, "session start timeout anchor"
s = s.replace(old_timeout, "#define SESSION_START_TIMEOUT_SEC 60 /* visionOS: was 30 */")
old_decoder = """static ChiakiErrorCode decode_customdata1(const char *customdata1, uint8_t *out, size_t out_len)
{
    uint8_t customdata1_round1[24];
    size_t decoded_len = sizeof(customdata1_round1);
    ChiakiErrorCode err = chiaki_base64_decode(customdata1, strlen(customdata1), customdata1_round1, &decoded_len);
    if (err != CHIAKI_ERR_SUCCESS)
        return err;
    err = chiaki_base64_decode((const char*)customdata1_round1, decoded_len, out, &decoded_len);
    if (err != CHIAKI_ERR_SUCCESS)
        return err;
    if (decoded_len != out_len)
        return CHIAKI_ERR_UNKNOWN;
    return CHIAKI_ERR_SUCCESS;
}"""
new_decoder = """static ChiakiErrorCode decode_customdata1(ChiakiLog *log, const char *customdata1, uint8_t *out, size_t out_len)
{
    return chiaki_psn_decode_custom_data1(log, customdata1, out, out_len);
}"""
assert s.count(old_decoder) == 1, "customData1 decoder anchor"
s = s.replace(old_decoder, new_decoder)
old_decl = "static ChiakiErrorCode decode_customdata1(const char *customdata1, uint8_t *out, size_t out_len);"
assert s.count(old_decl) == 1, "customData1 declaration anchor"
s = s.replace(old_decl, old_decl.replace("(const char", "(ChiakiLog *log, const char"))
old_call = "decode_customdata1(custom_data1, session->custom_data1, sizeof(session->custom_data1))"
assert s.count(old_call) == 1, "customData1 call anchor"
s = s.replace(old_call, old_call.replace("(custom_data1", "(session->log, custom_data1"))
old_include = "#include <chiaki/base64.h>"
assert s.count(old_include) == 1, "base64 include anchor"
s = s.replace(old_include, old_include + '\n#include "PSNCustomData.h"')
old_log = r'''"chiaki_holepunch_session_start: Failed to decode \"customData1\": '%s' with error %s", custom_data1, chiaki_error_string(err)'''
new_log = r'''"chiaki_holepunch_session_start: Failed to decode \"customData1\" (encoded length %zu): %s", strlen(custom_data1), chiaki_error_string(err)'''
assert s.count(old_log) == 1, "customData1 private log anchor"
s = s.replace(old_log, new_log)
open(p, "w").write(s)
print("  applied ws-failure and bounded customData1 fixes to the temp copy")
PY
sed -i '' 's|#include "../utils.h"|#include "utils.h"|' "$TEMP_DIR/holepunch.c"

echo "Compiling remote/holepunch.c (patched copy)..."
"$CLANG" "${CFLAGS[@]}" -I"$CHIAKI_DIR/lib/src" -c "$TEMP_DIR/holepunch.c" -o "$TEMP_DIR/holepunch.c.o"
echo "  compiled"
if nm "$TEMP_DIR/holepunch.c.o" | rg -q " U _curl_easy_init$"; then
  echo "  ERROR: curl_easy_init was not redirected"; exit 1
fi
nm "$TEMP_DIR/holepunch.c.o" | rg -q " U _chiaki_visionos_curl_easy_init$" && echo "  curl_easy_init -> chiaki_visionos_curl_easy_init"

# Backup (never touch .orig / .backup, which merge_chiaki_opus.sh depends on)
if [ ! -f "${LIB_PATH}.pre-holepunch-tls" ]; then
  cp "$LIB_PATH" "${LIB_PATH}.pre-holepunch-tls"
  echo "  backup: libchiaki_full.a.pre-holepunch-tls"
fi

# Replace only the holepunch member in place. Do NOT extract-all + libtool: the merged
# archive has members with identical basenames (chiaki base64.c.o vs curl base64.c.o,
# ...) which overwrite each other on extraction and silently drop symbols.
"$AR" r "$LIB_PATH" "$TEMP_DIR/holepunch.c.o"
"$(xcrun --sdk xros --find ranlib)" "$LIB_PATH"
echo "  replaced holepunch.c.o in libchiaki_full.a"
cd "$PROJECT_DIR"
rm -rf "$TEMP_DIR"
ls -la "$LIB_PATH"
echo "=== Done. Rebuild the Xcode project. ==="
