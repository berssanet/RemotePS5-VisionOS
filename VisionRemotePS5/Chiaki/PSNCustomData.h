#ifndef PSN_CUSTOM_DATA_H
#define PSN_CUSTOM_DATA_H

#include <chiaki/base64.h>
#include <chiaki/log.h>
#include <string.h>

static inline bool chiaki_psn_custom_data_base64_is_valid(const uint8_t *text, size_t size) {
  if (size == 0 || size % 4 != 0)
    return false;
  size_t end = size;
  if (text[end - 1] == '=') {
    --end;
    if (text[end - 1] == '=')
      --end;
  }
  for (size_t i = 0; i < end; ++i) {
    uint8_t c = text[i];
    if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') || c == '+' || c == '/'))
      return false;
  }
  return true;
}

static inline ChiakiErrorCode chiaki_psn_decode_custom_data1(
    ChiakiLog *log, const char *encoded, uint8_t *out, size_t out_len) {
  if (!encoded || !out || out_len != 16)
    return CHIAKI_ERR_INVALID_DATA;
  size_t encoded_len = strlen(encoded);
  if (encoded_len != 32 || !chiaki_psn_custom_data_base64_is_valid((const uint8_t *)encoded, encoded_len))
    return CHIAKI_ERR_INVALID_DATA;

  uint8_t round1[24];
  uint8_t round2[24];
  size_t round1_len = sizeof(round1);
  size_t round2_len = sizeof(round2);
  ChiakiErrorCode err = chiaki_base64_decode(encoded, encoded_len, round1, &round1_len);
  if (err != CHIAKI_ERR_SUCCESS)
    return err;
  if (!chiaki_psn_custom_data_base64_is_valid(round1, round1_len))
    return CHIAKI_ERR_INVALID_DATA;
  err = chiaki_base64_decode((const char *)round1, round1_len, round2, &round2_len);
  if (err != CHIAKI_ERR_SUCCESS)
    return err;
  if (round2_len < out_len || round2_len > out_len + 4)
    return CHIAKI_ERR_INVALID_DATA;

  if (log && round2_len > out_len)
    CHIAKI_LOGI(log, "PSN customData1: decoded %zu bytes; using the 16-byte registration value", round2_len);
  memcpy(out, round2, out_len);
  return CHIAKI_ERR_SUCCESS;
}

#endif
