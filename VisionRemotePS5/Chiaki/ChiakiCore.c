//
// ChiakiCore.c
// VisionRemotePS5
//
// Wrapper implementation linking against libchiaki.a (via Chiaki.xcframework)
// Created by Agentic AI
//

// CRITICAL: Define CHIAKI_LIB_ENABLE_OPUS=1 BEFORE including any chiaki
// headers! The Chiaki.xcframework was compiled with OPUS enabled, which changes
// the struct layouts (ChiakiSession is 4512 bytes with OPUS vs 3568 without).
// Without this define, our code will use wrong memory offsets causing
// corruption.
#define CHIAKI_LIB_ENABLE_OPUS 1

#include "ChiakiCore.h"
#include <stddef.h> // for offsetof

// Public headers from Chiaki.xcframework
// Ensure Chiaki.xcframework is added to your target's Link Binary With
// Libraries and Framework Search Paths include the framework.
#include <chiaki/base64.h>
#include <chiaki/common.h>
#include <chiaki/random.h>
#include <chiaki/regist.h>
#include <chiaki/remote/holepunch.h>
#include <chiaki/rpcrypt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Helper to disable warnings for stubs
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"

// ===========================================
//  Helper Structs and Globals
// ===========================================

typedef struct {
  ChiakiRPCrypt rpcrypt;
  uint64_t crypt_counter;
  bool initialized;
} SessionCryptoState;

static SessionCryptoState g_session_crypto = {0};

// ===========================================
//  Stubs (Required by legacy Swift bridge)
// ===========================================

CHIAKI_EXPORT ChiakiErrorCode chiaki_socket_set_nonblock(chiaki_socket_t sock,
                                                         bool nonblock) {
  return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT chiaki_socket_t *
chiaki_get_holepunch_sock(ChiakiHolepunchSession session,
                          ChiakiHolepunchPortType type) {
  return NULL;
}

CHIAKI_EXPORT uint16_t chiaki_get_ps_ctrl_port(ChiakiHolepunchSession session) {
  return 0;
}

CHIAKI_EXPORT void chiaki_get_ps_selected_addr(ChiakiHolepunchSession session,
                                               char *ps_ip) {
  if (ps_ip)
    ps_ip[0] = '\0';
}

CHIAKI_EXPORT ChiakiHolepunchRegistInfo
chiaki_get_regist_info(ChiakiHolepunchSession session) {
  ChiakiHolepunchRegistInfo info = {0};
  return info;
}

CHIAKI_EXPORT void
chiaki_holepunch_session_fini(ChiakiHolepunchSession session) {}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_session_punch_hole(
    ChiakiHolepunchSession session, ChiakiHolepunchPortType port_type) {
  return CHIAKI_ERR_UNKNOWN;
}

CHIAKI_EXPORT ChiakiErrorCode
holepunch_session_create_offer(ChiakiHolepunchSession session) {
  return CHIAKI_ERR_UNKNOWN;
}

// ===========================================
//  Registration Wrappers
// ===========================================

CHIAKI_EXPORT ChiakiErrorCode chiaki_format_regist_payload_wrapper(
    ChiakiTarget target, const uint8_t *ambassador,
    const uint8_t *psn_account_id, uint32_t pin, uint8_t *out_payload,
    size_t *out_payload_size, uint8_t *out_bright_key,
    uint8_t *out_ambassador_key) {
  ChiakiRPCrypt crypt;
  size_t buf_size = *out_payload_size;

  // Call the real function from libchiaki
  ChiakiErrorCode err = chiaki_regist_request_payload_format(
      target, ambassador, out_payload, &buf_size, &crypt, NULL, psn_account_id,
      pin, NULL);

  if (err == CHIAKI_ERR_SUCCESS) {
    *out_payload_size = buf_size;
    memcpy(out_bright_key, crypt.bright, 16);
    memcpy(out_ambassador_key, crypt.ambassador, 16);
    fprintf(stderr, "[C-CORE] Payload formatted: %zu bytes\n", buf_size);
  }
  return err;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_decrypt_regist_response_wrapper(
    ChiakiTarget target, const uint8_t *bright_key,
    const uint8_t *ambassador_key, const uint8_t *encrypted_data,
    size_t data_size, ChiakiRegisteredHost *out_host) {
  if (!bright_key || !ambassador_key || !encrypted_data || !out_host ||
      data_size == 0) {
    return CHIAKI_ERR_INVALID_DATA;
  }

  ChiakiRPCrypt rpcrypt;
  memset(&rpcrypt, 0, sizeof(rpcrypt));
  rpcrypt.target = target;
  memcpy(rpcrypt.bright, bright_key, 16);
  memcpy(rpcrypt.ambassador, ambassador_key, 16);

  uint8_t *decrypted = malloc(data_size);
  if (!decrypted)
    return CHIAKI_ERR_MEMORY;

  ChiakiErrorCode err =
      chiaki_rpcrypt_decrypt(&rpcrypt, 0, encrypted_data, decrypted, data_size);
  if (err != CHIAKI_ERR_SUCCESS) {
    free(decrypted);
    return err;
  }

  // Manual Parsing Logic
  memset(out_host, 0, sizeof(*out_host));
  out_host->target = target;

  char *line = (char *)decrypted;
  char *end = (char *)decrypted + data_size;

  while (line < end) {
    char *line_end = strstr(line, "\r\n");
    if (!line_end)
      break;
    *line_end = '\0';

    char *colon = strchr(line, ':');
    if (colon) {
      *colon = '\0';
      char *key = line;
      char *value = colon + 1;
      while (*value == ' ')
        value++;

      if (strcmp(key, "RP-Key") == 0) {
        size_t len = strlen(value);
        if (len >= 32) {
          for (int i = 0; i < 16; i++)
            sscanf(value + i * 2, "%2hhx", &out_host->rp_key[i]);
        }
      } else if (strcmp(key, "PS5-RegistKey") == 0 ||
                 strcmp(key, "PS4-RegistKey") == 0) {
        size_t len = strlen(value);
        if (len >= 2 && len <= sizeof(out_host->rp_regist_key) * 2) {
          size_t byte_count = len / 2;
          memset(out_host->rp_regist_key, 0, sizeof(out_host->rp_regist_key));
          for (size_t i = 0; i < byte_count; i++)
            sscanf(value + i * 2, "%2hhx", &out_host->rp_regist_key[i]);
        }
      } else if (strcmp(key, "PS5-Mac") == 0 || strcmp(key, "PS4-Mac") == 0) {
        size_t len = strlen(value);
        if (len >= 12) {
          for (int i = 0; i < 6; i++)
            sscanf(value + i * 2, "%2hhx", &out_host->server_mac[i]);
        }
      } else if (strcmp(key, "PS5-Nickname") == 0 ||
                 strcmp(key, "PS4-Nickname") == 0) {
        size_t len = strlen(value);
        if (len < sizeof(out_host->server_nickname))
          memcpy(out_host->server_nickname, value, len);
      } else if (strcmp(key, "RP-KeyType") == 0) {
        out_host->rp_key_type = (uint32_t)strtoul(value, NULL, 0);
      }
    }
    line = line_end + 2;
  }

  free(decrypted);
  return CHIAKI_ERR_SUCCESS;
}

// ===========================================
//  Session Wrappers
// ===========================================

CHIAKI_EXPORT ChiakiErrorCode chiaki_session_crypto_init_wrapper(
    ChiakiTarget target, const uint8_t *nonce, const uint8_t *morning) {
  chiaki_rpcrypt_init_auth(&g_session_crypto.rpcrypt, target, nonce, morning);
  g_session_crypto.crypt_counter = 0;
  g_session_crypto.initialized = true;
  return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_session_encrypt_header_wrapper(
    const uint8_t *data, size_t data_size, char *out_base64,
    size_t base64_buf_size) {
  if (!g_session_crypto.initialized)
    return CHIAKI_ERR_UNINITIALIZED;

  uint8_t *encrypted = malloc(data_size);
  if (!encrypted)
    return CHIAKI_ERR_MEMORY;

  ChiakiErrorCode err = chiaki_rpcrypt_encrypt(&g_session_crypto.rpcrypt,
                                               g_session_crypto.crypt_counter++,
                                               data, encrypted, data_size);
  if (err != CHIAKI_ERR_SUCCESS) {
    free(encrypted);
    return err;
  }

  err = chiaki_base64_encode(encrypted, data_size, out_base64, base64_buf_size);
  free(encrypted);
  return err;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_session_generate_headers_wrapper(
    ChiakiTarget target, const uint8_t *nonce, const uint8_t *rp_key,
    const uint8_t *regist_key, const uint8_t *device_id, char *out_rp_auth,
    char *out_rp_did, char *out_rp_ostype) {
  ChiakiErrorCode err =
      chiaki_session_crypto_init_wrapper(target, nonce, rp_key);
  if (err != CHIAKI_ERR_SUCCESS)
    return err;

  err = chiaki_session_encrypt_header_wrapper(
      regist_key, CHIAKI_RPCRYPT_KEY_SIZE, out_rp_auth, 64);
  if (err != CHIAKI_ERR_SUCCESS)
    return err;

  err = chiaki_session_encrypt_header_wrapper(device_id, 32, out_rp_did, 64);
  if (err != CHIAKI_ERR_SUCCESS)
    return err;

  const char *ostype = "Win10.0.0";
  err = chiaki_session_encrypt_header_wrapper(
      (const uint8_t *)ostype, strlen(ostype) + 1, out_rp_ostype, 256);
  return err;
}

CHIAKI_EXPORT ChiakiErrorCode
chiaki_session_generate_bitrate_wrapper(char *out_bitrate, size_t buf_size) {
  uint8_t bitrate_buf[4] = {0x00, 0x00, 0x00, 0x00};
  return chiaki_session_encrypt_header_wrapper(bitrate_buf, 4, out_bitrate,
                                               buf_size);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_session_generate_streaming_type_wrapper(
    char *out_streaming_type, size_t buf_size) {
  uint8_t streaming_type_buf[4] = {0x01, 0x00, 0x00, 0x00};
  return chiaki_session_encrypt_header_wrapper(streaming_type_buf, 4,
                                               out_streaming_type, buf_size);
}

CHIAKI_EXPORT void chiaki_session_crypto_reset_wrapper(void) {
  memset(&g_session_crypto, 0, sizeof(g_session_crypto));
}

// ===========================================
//  Full Streaming Session Wrapper
//  Architecture based on Android chiaki-jni.c
// ===========================================

#include <chiaki/log.h>
#include <chiaki/session.h>

// VisionOS Session Wrapper (using pointer to avoid ABI issues)
// Using pointer to ChiakiSession instead of embedding it to avoid
// struct layout mismatches between compilation units.
typedef struct visionos_chiaki_session_t {
  ChiakiSession *session; // Pointer to avoid ABI mismatch
  ChiakiLog log;
  // Swift callbacks stored in the wrapper
  ChiakiWrapperVideoCallback video_callback;
  ChiakiWrapperAudioCallback audio_callback;
  ChiakiWrapperEventCallback event_callback;
  ChiakiWrapperRumbleCallback rumble_callback;
  void *callback_user; // User data passed from Swift
} VisionOSChiakiSession;

// Global session instance (wrapper struct, not raw ChiakiSession)
static VisionOSChiakiSession *g_active_session = NULL;

// Video sample callback for ChiakiSession
// Following Android pattern: receives wrapper struct as user parameter
static int g_video_frame_count = 0;
static bool session_video_sample_cb(uint8_t *buf, size_t buf_size,
                                    int32_t frames_lost, bool frame_recovered,
                                    void *user) {
  VisionOSChiakiSession *wrapper = (VisionOSChiakiSession *)user;
  g_video_frame_count++;

  // Log first 10 frames to debug startup
  if (g_video_frame_count <= 10 || g_video_frame_count % 60 == 1) {
    fprintf(stderr,
            "[ChiakiSession] 📹 Video callback #%d: size=%zu, lost=%d, "
            "recovered=%d\n",
            g_video_frame_count, buf_size, frames_lost, frame_recovered);
  }

  // Safety checks
  if (!buf || buf_size == 0) {
    fprintf(
        stderr,
        "[ChiakiSession] ⚠️ Video callback received NULL buffer or zero size\n");
    return false;
  }

  if (!wrapper) {
    fprintf(stderr, "[ChiakiSession] ⚠️ Wrapper is NULL in video callback!\n");
    return false;
  }

  if (wrapper->video_callback) {
    wrapper->video_callback(buf, buf_size, wrapper->callback_user);
    if (g_video_frame_count <= 10) {
      fprintf(stderr,
              "[ChiakiSession] ✅ Forwarded frame #%d to Swift (%zu bytes)\n",
              g_video_frame_count, buf_size);
    }
    return true;
  } else {
    if (g_video_frame_count <= 5) {
      fprintf(stderr, "[ChiakiSession] ⚠️ video_callback is NULL!\n");
    }
    return false;
  }
}

// Audio frame callback for ChiakiSession (matches ChiakiAudioSinkFrame
// signature)
// Following Android pattern: receives wrapper struct as user parameter
static int g_audio_frame_count = 0;
static void session_audio_frame_cb(uint8_t *buf, size_t buf_size, void *user) {
  VisionOSChiakiSession *wrapper = (VisionOSChiakiSession *)user;

  // Safety checks to prevent crash
  if (!buf || buf_size == 0) {
    fprintf(stderr,
            "[ChiakiSession] ⚠️ Audio callback with invalid buffer: buf=%p, "
            "size=%zu\n",
            (void *)buf, buf_size);
    return;
  }

  if (!wrapper) {
    fprintf(stderr, "[ChiakiSession] ⚠️ Audio callback with NULL wrapper\n");
    return;
  }

  g_audio_frame_count++;
  if (g_audio_frame_count <= 3 || g_audio_frame_count % 100 == 0) {
    fprintf(stderr, "[ChiakiSession] 🔊 Audio frame #%d: buf=%p, size=%zu\n",
            g_audio_frame_count, (void *)buf, buf_size);
  }

  if (wrapper->audio_callback) {
    wrapper->audio_callback((int16_t *)buf, buf_size / sizeof(int16_t),
                            wrapper->callback_user);
  }
}

// Audio header callback
static void session_audio_header_cb(ChiakiAudioHeader *header, void *user) {
  fprintf(stderr, "[ChiakiSession] Audio header: channels=%u, rate=%u\n",
          header->channels, header->rate);
}

// Event callback for ChiakiSession
// Following Android pattern: receives wrapper struct as user parameter
static void session_event_cb(ChiakiEvent *event, void *user) {
  VisionOSChiakiSession *wrapper = (VisionOSChiakiSession *)user;
  if (!event)
    return;

  const char *reason = NULL;

  switch (event->type) {
  case CHIAKI_EVENT_CONNECTED:
    fprintf(stderr, "[ChiakiSession] ✅ CONNECTED!\n");
    break;
  case CHIAKI_EVENT_QUIT:
    reason = event->quit.reason_str
                 ? event->quit.reason_str
                 : chiaki_quit_reason_string(event->quit.reason);
    fprintf(stderr, "[ChiakiSession] ❌ QUIT: %s\n", reason);
    break;
  case CHIAKI_EVENT_RUMBLE:
    fprintf(stderr, "[ChiakiSession] Rumble: L=%u R=%u\n", event->rumble.left,
            event->rumble.right);
    if (wrapper && wrapper->rumble_callback) {
      wrapper->rumble_callback(event->rumble.left, event->rumble.right,
                               wrapper->callback_user);
    }
    break;
  default:
    fprintf(stderr, "[ChiakiSession] Event type=%d\n", event->type);
    break;
  }

  if (wrapper && wrapper->event_callback) {
    wrapper->event_callback(event->type, reason, wrapper->callback_user);
  }
}

// Custom log callback
static void chiaki_log_cb(ChiakiLogLevel level, const char *msg, void *user) {
  const char *level_str = "???";
  switch (level) {
  case CHIAKI_LOG_DEBUG:
    level_str = "DBG";
    break;
  case CHIAKI_LOG_VERBOSE:
    level_str = "VRB";
    break;
  case CHIAKI_LOG_INFO:
    level_str = "INF";
    break;
  case CHIAKI_LOG_WARNING:
    level_str = "WRN";
    break;
  case CHIAKI_LOG_ERROR:
    level_str = "ERR";
    break;
  }
  fprintf(stderr, "[Chiaki/%s] %s\n", level_str, msg);
}

// Set rumble callback (call this before starting session)
CHIAKI_EXPORT void
chiaki_set_rumble_callback_wrapper(ChiakiWrapperRumbleCallback rumble_cb) {
  if (g_active_session) {
    g_active_session->rumble_callback = rumble_cb;
  }
}

// Initialize and start a streaming session
// Following Android's sessionCreate pattern from chiaki-jni.c
CHIAKI_EXPORT ChiakiErrorCode chiaki_fullsession_start_wrapper(
    const char *host,
    const uint8_t *regist_key,     // 16 bytes
    const uint8_t *morning,        // 16 bytes (RP-Key)
    const uint8_t *psn_account_id, // 8 bytes
    uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate,
    bool is_ps5, ChiakiWrapperVideoCallback video_cb,
    ChiakiWrapperAudioCallback audio_cb, ChiakiWrapperEventCallback event_cb,
    void *user_data) {
  if (g_active_session) {
    fprintf(stderr, "[ChiakiSession] Session already active\n");
    return CHIAKI_ERR_UNKNOWN;
  }

  // Allocate wrapper struct
  g_active_session = calloc(1, sizeof(VisionOSChiakiSession));
  if (!g_active_session) {
    return CHIAKI_ERR_MEMORY;
  }

// CRITICAL FIX: XCFramework's chiaki_session_init does memset(session, 0, 4512)
// but our headers define sizeof(ChiakiSession) = 3568 bytes.
// The library was compiled with different struct sizes (probably with OPUS
// enabled which adds extra fields). We MUST allocate enough memory for the
// library's expected size to prevent buffer overflow corruption! 4512 (0x11A0)
// = actual library size, 3568 = our header size, diff = 944 bytes
#define CHIAKI_SESSION_LIBRARY_SIZE 4512
  g_active_session->session = malloc(CHIAKI_SESSION_LIBRARY_SIZE);
  if (!g_active_session->session) {
    free(g_active_session);
    g_active_session = NULL;
    return CHIAKI_ERR_MEMORY;
  }
  memset(g_active_session->session, 0, CHIAKI_SESSION_LIBRARY_SIZE);

  // Store callbacks IN the wrapper struct (not globals)
  g_active_session->video_callback = video_cb;
  g_active_session->audio_callback = audio_cb;
  g_active_session->event_callback = event_cb;
  g_active_session->callback_user = user_data;

  fprintf(stderr, "[ChiakiCore] Allocated VisionOSChiakiSession=%p\n",
          (void *)g_active_session);
  fprintf(stderr, "[ChiakiCore] Allocated ChiakiSession=%p (size=%zu)\n",
          (void *)g_active_session->session, sizeof(ChiakiSession));
  fprintf(stderr, "[ChiakiCore] video_callback=%p, audio_callback=%p\n",
          (void *)video_cb, (void *)audio_cb);

  // Initialize log inside wrapper
  chiaki_log_init(&g_active_session->log, CHIAKI_LOG_ALL, chiaki_log_cb, NULL);

  // Test if log callback works
  CHIAKI_LOGI(&g_active_session->log, "TEST: Log callback is working!");
  fprintf(stderr, "[ChiakiCore] chiaki_log_init completed, log ptr=%p\n",
          (void *)&g_active_session->log);

  // DEBUG: Print struct sizes to detect ABI mismatch
  fprintf(stderr, "[ChiakiCore] DEBUG ABI: sizeof(ChiakiSession)=%zu\n",
          sizeof(ChiakiSession));
  fprintf(stderr, "[ChiakiCore] DEBUG ABI: sizeof(VisionOSChiakiSession)=%zu\n",
          sizeof(VisionOSChiakiSession));

  // Build connect info
  ChiakiConnectInfo connect_info = {0};
  connect_info.ps5 = is_ps5;
  connect_info.host = host;
  memcpy(connect_info.regist_key, regist_key, CHIAKI_SESSION_AUTH_SIZE);
  memcpy(connect_info.morning, morning, 16);

  connect_info.video_profile.width = width;
  connect_info.video_profile.height = height;
  connect_info.video_profile.max_fps = fps;
  connect_info.video_profile.bitrate = bitrate;
  connect_info.video_profile.codec =
      is_ps5 ? CHIAKI_CODEC_H265
             : CHIAKI_CODEC_H264; // SDR for now - HDR causes color mismatch

  connect_info.video_profile_auto_downgrade = true;
  connect_info.enable_keyboard = false;
  connect_info.enable_dualsense = is_ps5;
  connect_info.audio_video_disabled = CHIAKI_NONE_DISABLED;
  connect_info.packet_loss_max = 0.05;

  if (psn_account_id) {
    memcpy(connect_info.psn_account_id, psn_account_id,
           CHIAKI_PSN_ACCOUNT_ID_SIZE);
  }

  // Initialize session (as MEMBER of wrapper, like Android)
  ChiakiErrorCode err = chiaki_session_init(
      g_active_session->session, &connect_info, &g_active_session->log);
  if (err != CHIAKI_ERR_SUCCESS) {
    fprintf(stderr, "[ChiakiSession] Init failed: %d\n", err);
    free(g_active_session->session);
    free(g_active_session);
    g_active_session = NULL;
    return err;
  }

  // Set callbacks - PASS WRAPPER AS USER_DATA (this is the key fix!)
  // Following Android pattern:
  // chiaki_session_set_video_sample_cb(&session->session, callback,
  // &session->video_decoder);
  chiaki_session_set_event_cb(g_active_session->session, session_event_cb,
                              g_active_session);

// CRITICAL ABI FIX: The library's ChiakiSession struct has a DIFFERENT layout
// than what our headers define. The library uses offset 1552 (0x610) for
// video_sample_cb, but our headers calculate offset 608 (0x260).
//
// The 944-byte difference comes from differently-sized internal structs
// that are not exposed in the public headers.
//
// We MUST write directly to the offset the library expects, NOT use the
// inline function which uses our incorrect offsets.
#define LIBRARY_VIDEO_SAMPLE_CB_OFFSET 1552
#define LIBRARY_VIDEO_SAMPLE_CB_USER_OFFSET 1560

  uint8_t *session_bytes = (uint8_t *)g_active_session->session;
  *((ChiakiVideoSampleCallback *)(session_bytes +
                                  LIBRARY_VIDEO_SAMPLE_CB_OFFSET)) =
      session_video_sample_cb;
  *((void **)(session_bytes + LIBRARY_VIDEO_SAMPLE_CB_USER_OFFSET)) =
      g_active_session;

  // Also set at our header's offset as a fallback (the library might read from
  // here too)
  chiaki_session_set_video_sample_cb(g_active_session->session,
                                     session_video_sample_cb, g_active_session);

  fprintf(stderr, "[ChiakiCore] Set callbacks with wrapper=%p as user_data\n",
          (void *)g_active_session);

  // DEBUG: Verify callback was set correctly by reading it back
  fprintf(stderr, "[ChiakiCore] DEBUG: video_sample_cb=%p (expected=%p)\n",
          (void *)g_active_session->session->video_sample_cb,
          (void *)session_video_sample_cb);
  fprintf(stderr, "[ChiakiCore] DEBUG: video_sample_cb_user=%p (expected=%p)\n",
          (void *)g_active_session->session->video_sample_cb_user,
          (void *)g_active_session);

  // DEBUG: Print exact offset of video_sample_cb field
  fprintf(
      stderr,
      "[ChiakiCore] DEBUG ABI: offsetof(ChiakiSession, video_sample_cb)=%zu\n",
      offsetof(ChiakiSession, video_sample_cb));
  fprintf(stderr,
          "[ChiakiCore] DEBUG ABI: offsetof(ChiakiSession, "
          "video_sample_cb_user)=%zu\n",
          offsetof(ChiakiSession, video_sample_cb_user));
  fprintf(stderr,
          "[ChiakiCore] DEBUG ABI: offsetof(ChiakiSession, event_cb)=%zu\n",
          offsetof(ChiakiSession, event_cb));
  fprintf(stderr,
          "[ChiakiCore] DEBUG ABI: offsetof(ChiakiSession, audio_sink)=%zu\n",
          offsetof(ChiakiSession, audio_sink));

  // Set audio sink with wrapper as user
  ChiakiAudioSink audio_sink = {0};
  audio_sink.user = g_active_session;
  audio_sink.header_cb = session_audio_header_cb;
  audio_sink.frame_cb = session_audio_frame_cb;
  chiaki_session_set_audio_sink(g_active_session->session, &audio_sink);

  // Start session (spawns thread)
  fprintf(stderr,
          "[ChiakiCore] DEBUG: About to call chiaki_session_start...\n");
  fprintf(stderr, "[ChiakiCore] DEBUG: connect_info.host=%s, ps5=%d\n",
          connect_info.host, connect_info.ps5);
  fprintf(stderr, "[ChiakiCore] DEBUG: session ptr=%p, log ptr=%p\n",
          (void *)g_active_session->session, (void *)&g_active_session->log);
  err = chiaki_session_start(g_active_session->session);
  fprintf(stderr, "[ChiakiCore] DEBUG: chiaki_session_start returned %d\n",
          err);
  if (err != CHIAKI_ERR_SUCCESS) {
    fprintf(stderr, "[ChiakiSession] Start failed: %d\n", err);
    chiaki_session_fini(g_active_session->session);
    free(g_active_session->session);
    free(g_active_session);
    g_active_session = NULL;
    return err;
  }

  fprintf(stderr, "[ChiakiSession] ✅ Session started for %s\n", host);
  return CHIAKI_ERR_SUCCESS;
}

// Stop the active session
CHIAKI_EXPORT ChiakiErrorCode chiaki_fullsession_stop_wrapper(void) {
  if (!g_active_session) {
    return CHIAKI_ERR_UNINITIALIZED;
  }

  fprintf(stderr, "[ChiakiSession] Stopping session...\n");

  ChiakiErrorCode err = chiaki_session_stop(g_active_session->session);
  if (err != CHIAKI_ERR_SUCCESS) {
    fprintf(stderr, "[ChiakiSession] Stop error: %d\n", err);
  }

  // Wait for session thread to finish
  err = chiaki_session_join(g_active_session->session);
  if (err != CHIAKI_ERR_SUCCESS) {
    fprintf(stderr, "[ChiakiSession] Join error: %d\n", err);
  }

  chiaki_session_fini(g_active_session->session);
  free(g_active_session->session); // Free the session first
  free(g_active_session);
  g_active_session = NULL;

  fprintf(stderr, "[ChiakiSession] ✅ Session stopped\n");
  return CHIAKI_ERR_SUCCESS;
}

// Set controller state
CHIAKI_EXPORT ChiakiErrorCode chiaki_fullsession_set_controller_wrapper(
    uint32_t buttons, int16_t left_x, int16_t left_y, int16_t right_x,
    int16_t right_y, uint8_t l2, uint8_t r2) {
  if (!g_active_session) {
    return CHIAKI_ERR_UNINITIALIZED;
  }

  ChiakiControllerState state = {0};
  state.buttons = buttons;
  state.left_x = left_x;
  state.left_y = left_y;
  state.right_x = right_x;
  state.right_y = right_y;
  state.l2_state = l2;
  state.r2_state = r2;

  return chiaki_session_set_controller_state(g_active_session->session, &state);
}

// Check if session is active
CHIAKI_EXPORT bool chiaki_fullsession_is_active_wrapper(void) {
  return g_active_session != NULL;
}

#pragma clang diagnostic pop

// ===========================================
//  Type-Safe Callback Helpers
//  These functions let the compiler calculate correct struct offsets
//  instead of using hardcoded magic numbers like 1552.
// ===========================================

/// Type-safe video callback setter
/// Using this function instead of manual offset calculation ensures
/// the callback is always written to the correct memory location.
CHIAKI_EXPORT void chiaki_session_set_video_callback_safe(
    ChiakiSession *session, ChiakiVideoSampleCallback callback, void *user) {
  if (!session)
    return;

  // Let the compiler calculate the correct offsets
  session->video_sample_cb = callback;
  session->video_sample_cb_user = user;

  fprintf(stderr,
          "[ChiakiCore] ✅ Video callback set safely via helper function\n");
  fprintf(stderr, "[ChiakiCore]    video_sample_cb=%p, user=%p\n",
          (void *)callback, user);
}

/// Type-safe audio sink setter
CHIAKI_EXPORT void
chiaki_session_set_audio_sink_safe(ChiakiSession *session, void *sink_user,
                                   ChiakiAudioSinkHeader header_cb,
                                   ChiakiAudioSinkFrame frame_cb) {
  if (!session)
    return;

  ChiakiAudioSink sink = {0};
  sink.user = sink_user;
  sink.header_cb = header_cb;
  sink.frame_cb = frame_cb;

  chiaki_session_set_audio_sink(session, &sink);

  fprintf(stderr,
          "[ChiakiCore] ✅ Audio sink set safely via helper function\n");
}

/// Type-safe event callback setter
CHIAKI_EXPORT void chiaki_session_set_event_callback_safe(
    ChiakiSession *session, ChiakiEventCallback callback, void *user) {
  if (!session)
    return;

  chiaki_session_set_event_cb(session, callback, user);

  fprintf(stderr,
          "[ChiakiCore] ✅ Event callback set safely via helper function\n");
}

/// Get the actual struct sizes for ABI verification
/// Call this to verify the library and header struct sizes match
CHIAKI_EXPORT void chiaki_get_struct_sizes(size_t *out_session_size,
                                           size_t *out_video_cb_offset,
                                           size_t *out_video_cb_user_offset,
                                           size_t *out_event_cb_offset) {
  if (out_session_size)
    *out_session_size = sizeof(ChiakiSession);
  if (out_video_cb_offset)
    *out_video_cb_offset = offsetof(ChiakiSession, video_sample_cb);
  if (out_video_cb_user_offset)
    *out_video_cb_user_offset = offsetof(ChiakiSession, video_sample_cb_user);
  if (out_event_cb_offset)
    *out_event_cb_offset = offsetof(ChiakiSession, event_cb);
}

// End of ChiakiCore.c
