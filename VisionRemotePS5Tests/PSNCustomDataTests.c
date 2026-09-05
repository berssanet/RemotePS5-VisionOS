#include "../VisionRemotePS5/Chiaki/PSNCustomData.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static char log_message[256];

static void capture_log(ChiakiLogLevel level, const char *message, void *user) {
  (void)level;
  (void)user;
  snprintf(log_message, sizeof(log_message), "%s", message);
}

static void encode_twice(const uint8_t *bytes, size_t size, char *encoded, size_t capacity) {
  char inner[64];
  assert(chiaki_base64_encode(bytes, size, inner, sizeof(inner)) == CHIAKI_ERR_SUCCESS);
  assert(chiaki_base64_encode((const uint8_t *)inner, strlen(inner), encoded, capacity) == CHIAKI_ERR_SUCCESS);
}

static void test_supported_lengths(void) {
  uint8_t bytes[18];
  for (size_t i = 0; i < sizeof(bytes); ++i)
    bytes[i] = (uint8_t)(i * 13);
  ChiakiLog log;
  chiaki_log_init(&log, CHIAKI_LOG_ALL, capture_log, NULL);

  for (size_t size = 16; size <= 18; ++size) {
    char encoded[64];
    encode_twice(bytes, size, encoded, sizeof(encoded));
    assert(strlen(encoded) == 32);
    uint8_t *out = malloc(16);
    assert(out);
    memset(out, 0xa5, 16);
    log_message[0] = '\0';
    assert(chiaki_psn_decode_custom_data1(&log, encoded, out, 16) == CHIAKI_ERR_SUCCESS);
    assert(memcmp(out, bytes, 16) == 0);
    if (size > 16) {
      assert(strstr(log_message, "16-byte registration value"));
      assert(!strstr(log_message, encoded));
    } else {
      assert(log_message[0] == '\0');
    }
    free(out);
  }
}

static void assert_rejected(const char *encoded, size_t capacity) {
  uint8_t out[16];
  uint8_t expected[16];
  memset(out, 0xa5, sizeof(out));
  memcpy(expected, out, sizeof(out));
  assert(chiaki_psn_decode_custom_data1(NULL, encoded, out, capacity) != CHIAKI_ERR_SUCCESS);
  assert(memcmp(out, expected, sizeof(out)) == 0);
}

static void test_rejected_inputs(void) {
  uint8_t bytes[32] = {0};
  char encoded[128];
  for (size_t size = 0; size < 16; ++size) {
    encode_twice(bytes, size, encoded, sizeof(encoded));
    assert_rejected(encoded, 16);
  }
  for (size_t size = 19; size <= sizeof(bytes); ++size) {
    encode_twice(bytes, size, encoded, sizeof(encoded));
    assert_rejected(encoded, 16);
  }
  encode_twice(bytes, 17, encoded, sizeof(encoded));
  assert_rejected(encoded, 0);
  assert_rejected(encoded, 15);
  assert_rejected(encoded, 17);
  assert_rejected(NULL, 16);
  assert_rejected("????????????????????????????????", 16);
  const char invalid_inner[] = "????????????????????????";
  assert(chiaki_base64_encode((const uint8_t *)invalid_inner, strlen(invalid_inner),
                             encoded, sizeof(encoded)) == CHIAKI_ERR_SUCCESS);
  assert_rejected(encoded, 16);
  assert(chiaki_psn_decode_custom_data1(NULL, encoded, NULL, 16) == CHIAKI_ERR_INVALID_DATA);
  uint8_t high_bytes[24];
  memset(high_bytes, 0xff, sizeof(high_bytes));
  assert(chiaki_base64_encode(high_bytes, sizeof(high_bytes), encoded, sizeof(encoded)) == CHIAKI_ERR_SUCCESS);
  assert_rejected(encoded, 16);
  memset(encoded, 0xff, 32);
  encoded[32] = '\0';
  assert_rejected(encoded, 16);
  const char invalid_padding[] = "AAAAAAAAAAAAAAAAAAAAA===";
  assert(chiaki_base64_encode((const uint8_t *)invalid_padding, strlen(invalid_padding),
                             encoded, sizeof(encoded)) == CHIAKI_ERR_SUCCESS);
  assert_rejected(encoded, 16);
}

int main(void) {
  test_supported_lengths();
  test_rejected_inputs();
  puts("PSN customData1 tests passed: 16/17/18-byte payloads, bounds, invalid inputs and redacted logs");
  return 0;
}
