#ifndef PSN_CONNECTION_DIAGNOSTICS_H
#define PSN_CONNECTION_DIAGNOSTICS_H

#include <stdbool.h>
#include <string.h>

static inline bool chiaki_psn_command_was_accepted(const char *message) {
  const char prefix[] = "Holepunch session state:";
  return message && strncmp(message, prefix, sizeof(prefix) - 1) == 0 &&
         strstr(message, "DATA_SENT") && !strstr(message, "CONSOLE_JOINED") &&
         !strstr(message, "DELETED");
}

#endif
