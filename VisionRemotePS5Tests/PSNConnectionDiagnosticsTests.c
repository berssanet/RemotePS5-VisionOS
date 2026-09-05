#include "../VisionRemotePS5/Chiaki/PSNConnectionDiagnostics.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
  assert(chiaki_psn_command_was_accepted(
      "Holepunch session state: 55 = [ INIT WS_OPEN CREATED CLIENT_JOINED DATA_SENT ]"));
  assert(!chiaki_psn_command_was_accepted(
      "Holepunch session state: 23 = [ INIT WS_OPEN CREATED CLIENT_JOINED ]"));
  assert(!chiaki_psn_command_was_accepted(
      "Holepunch session state: 119 = [ INIT DATA_SENT CONSOLE_JOINED ]"));
  assert(!chiaki_psn_command_was_accepted(
      "Holepunch session state: 262199 = [ INIT DELETED CREATED CLIENT_JOINED DATA_SENT ]"));
  assert(!chiaki_psn_command_was_accepted(
      "http_start_session: Received JSON:\n{\"commandId\":\"synthetic-private-id\"}"));
  assert(!chiaki_psn_command_was_accepted(
      "{\"access_token\":\"synthetic-private-token\",\"state\":\"DATA_SENT\"}"));
  assert(!chiaki_psn_command_was_accepted("DATA_SENT"));
  assert(!chiaki_psn_command_was_accepted(""));
  assert(!chiaki_psn_command_was_accepted(NULL));
  puts("PSN diagnostic assertions passed (9 checks)");
  return 0;
}
