//
//  ChiakiCore.h
//  VisionRemotePS5
//
//  Bridging header to expose chiaki-ng C functions to Swift
//  This header imports the core chiaki-ng APIs needed for PS5 authentication
//

#ifndef ChiakiCore_h
#define ChiakiCore_h

// Core chiaki-ng headers
#include "chiaki/common.h"
#include "chiaki/log.h"
#include "chiaki/regist.h"
#include "chiaki/rpcrypt.h"
#include "chiaki/thread.h"

// === Swift-callable wrapper for registration payload ===
// This function calls chiaki_regist_request_payload_format directly
ChiakiErrorCode chiaki_format_regist_payload_wrapper(
    ChiakiTarget target,
    const uint8_t *ambassador,     // 16 bytes (input random)
    const uint8_t *psn_account_id, // 8 bytes (raw, NOT base64)
    uint32_t pin,
    uint8_t *out_payload,       // Must be at least 0x400 bytes
    size_t *out_payload_size,   // Input: buffer size, Output: actual size
    uint8_t *out_bright_key,    // 16 bytes, receives the derived bright key
    uint8_t *out_ambassador_key // 16 bytes, receives the COMPUTED ambassador
);

// === Wrapper to decrypt registration response ===
// Decrypts the response body and parses host info
ChiakiErrorCode chiaki_decrypt_regist_response_wrapper(
    ChiakiTarget target,
    const uint8_t *bright_key,     // 16 bytes (from payload generation)
    const uint8_t *ambassador_key, // 16 bytes (from payload generation)
    const uint8_t *encrypted_data, // Response body after HTTP headers
    size_t data_size,
    ChiakiRegisteredHost *out_host // Output: parsed host info
);

// === Session Crypto Wrappers ===

// Initialize session crypto with nonce and morning (RP-Key)
ChiakiErrorCode
chiaki_session_crypto_init_wrapper(ChiakiTarget target,
                                   const uint8_t *nonce,  // 16 bytes
                                   const uint8_t *morning // 16 bytes (= RP-Key)
);

// Encrypt session header value and encode to base64
ChiakiErrorCode chiaki_session_encrypt_header_wrapper(
    const uint8_t *data,   // Input data to encrypt
    size_t data_size,      // Size of input data
    char *out_base64,      // Output base64 string buffer
    size_t base64_buf_size // Size of base64 buffer
);

// Generate all session headers at once (RP-Auth, RP-Did, RP-OSType)
// Must be called before sending session request
ChiakiErrorCode chiaki_session_generate_headers_wrapper(
    ChiakiTarget target,
    const uint8_t *nonce,      // 16 bytes from initial handshake
    const uint8_t *rp_key,     // 16 bytes (morning)
    const uint8_t *regist_key, // 16 bytes binary (NOT hex string)
    const uint8_t *device_id,  // 32 bytes
    char *out_rp_auth,         // Output: RP-Auth header (64 bytes)
    char *out_rp_did,          // Output: RP-Did header (64 bytes)
    char *out_rp_ostype        // Output: RP-OSType header (256 bytes)
);

// Reset session crypto state
void chiaki_session_crypto_reset_wrapper(void);

// Generate RP-StartBitrate header (required for PS5, counter 3)
ChiakiErrorCode chiaki_session_generate_bitrate_wrapper(char *out_bitrate,
                                                        size_t buf_size);

// Generate RP-StreamingType header (required for PS5, counter 4)
ChiakiErrorCode
chiaki_session_generate_streaming_type_wrapper(char *out_streaming_type,
                                               size_t buf_size);

// ===========================================
// Full Streaming Session API
// ===========================================

// Callback types for Swift bridge (prefixed with Wrapper to avoid conflicts)
typedef bool (*ChiakiWrapperVideoCallback)(uint8_t *buf, size_t buf_size,
                                           int32_t frames_lost, bool frame_recovered, void *user);
typedef void (*ChiakiWrapperAudioCallback)(int16_t *buf, size_t samples_count,
                                           void *user);
typedef void (*ChiakiWrapperEventCallback)(int event_type, const char *reason,
                                           void *user);
typedef void (*ChiakiWrapperRumbleCallback)(uint8_t left, uint8_t right,
                                            void *user);

// Start a streaming session with full protocol handling
// This handles: CTRL handshake, Senkusha, TAKION, BIG/BANG, streaminfo
ChiakiErrorCode chiaki_fullsession_start_wrapper(
    const char *host,                    // PS5 IP address
    const uint8_t *regist_key,           // 16 bytes (from registration)
    const uint8_t *morning,              // 16 bytes (RP-Key from registration)
    const uint8_t *psn_account_id,       // 8 bytes
    uint32_t width,                      // Video width (e.g. 1920)
    uint32_t height,                     // Video height (e.g. 1080)
    uint32_t fps,                        // Frames per second (30 or 60)
    uint32_t bitrate,                    // Bitrate in bps
    bool is_ps5,                         // true for PS5, false for PS4
    ChiakiWrapperVideoCallback video_cb, // Called when video frame received
    ChiakiWrapperAudioCallback audio_cb, // Called when audio samples received
    ChiakiWrapperEventCallback
        event_cb,   // Called for events (connect, quit, etc)
    void *user_data // User data passed to callbacks
);

// Stop the active streaming session
ChiakiErrorCode chiaki_fullsession_stop_wrapper(void);

// Set controller state (buttons, sticks, triggers)
ChiakiErrorCode chiaki_fullsession_set_controller_wrapper(
    uint32_t buttons, // Button bitmask (CHIAKI_CONTROLLER_BUTTON_*)
    int16_t left_x,   // Left stick X (-32768 to 32767)
    int16_t left_y,   // Left stick Y
    int16_t right_x,  // Right stick X
    int16_t right_y,  // Right stick Y
    uint8_t l2,       // L2 trigger (0-255)
    uint8_t r2        // R2 trigger (0-255)
);

// Check if a session is currently active
bool chiaki_fullsession_is_active_wrapper(void);

// Set rumble callback (call before starting session)
void chiaki_set_rumble_callback_wrapper(ChiakiWrapperRumbleCallback rumble_cb);

// ===========================================
// PSN (holepunch) session — no PIN, no IP (official Remote Play app flow)
// ===========================================

// Start a session through PSN: creates the push-notification session, sends the
// remotePlay command (wakes the console), punches the ctrl hole and lets session.c
// register the console over RUDP with the PSN-provided secret. With auto_regist the
// session stops right after CHIAKI_EVENT_REGIST (use the getter below to persist the
// keys); otherwise it continues into streaming. Blocking for several seconds: call
// from a background thread. console_duid = 32 bytes (the PSN device "duid" hex decoded).
ChiakiErrorCode chiaki_fullsession_start_psn_wrapper(
    const char *psn_oauth2_token, const uint8_t *console_duid, bool is_ps5,
    const uint8_t *psn_account_id, bool auto_regist, uint32_t width,
    uint32_t height, uint32_t fps, uint32_t bitrate,
    ChiakiWrapperVideoCallback video_cb, ChiakiWrapperAudioCallback audio_cb,
    ChiakiWrapperEventCallback event_cb, void *user_data);

// After CHIAKI_EVENT_REGIST: copies rp_key (16), regist key (16 raw bytes, zero padded),
// server MAC (6), nickname and the console address selected by the holepunch.
bool chiaki_fullsession_copy_registered_host_wrapper(
    uint8_t *out_rp_key, uint8_t *out_regist_key, uint8_t *out_server_mac,
    char *out_nickname, size_t nickname_size, char *out_console_ip,
    size_t console_ip_size);

// Path to a PEM CA bundle for the library's curl (mbedTLS backend has no system store).
// Call before any PSN session; Swift passes the bundled cacert.pem.
void chiaki_set_ca_bundle_path_wrapper(const char *path);

// Abort an in-flight PSN start (no-op once the library session started).
void chiaki_fullsession_cancel_psn_wrapper(void);

// True once chiaki_session_start succeeded (stop/join/fini are legal).
bool chiaki_fullsession_is_started_wrapper(void);

// Client DUID in PSN format ("0000000700410080" + 32 hex). The OAuth login URL must carry
// it as `duid=`; tokens minted without it are refused by the push WebSocket (holepunch.h).
// out_size must be >= 49.
bool chiaki_generate_client_duid_wrapper(char *out, size_t out_size);

#endif /* ChiakiCore_h */
