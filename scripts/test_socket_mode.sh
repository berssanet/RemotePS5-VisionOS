#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-socket-test.XXXXXX")
python3 - "$PROJECT_DIR" "$TEMP_DIR/test.c" <<'PY'
from pathlib import Path
import sys
s=(Path(sys.argv[1])/'VisionRemotePS5/Chiaki/ChiakiCore.c').read_text()
a=s.index('CHIAKI_EXPORT ChiakiErrorCode chiaki_socket_set_nonblock(')
b=s.index('\n}',a)+2
Path(sys.argv[2]).write_text('''#include <chiaki/sock.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <assert.h>
#include <unistd.h>
#include <stdio.h>
'''+s[a:b]+'''
int main(void) {
 int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
 int before = fcntl(pair[0], F_GETFL);
 assert(chiaki_socket_set_nonblock(pair[0], true) == CHIAKI_ERR_SUCCESS);
 assert(fcntl(pair[0], F_GETFL) == (before | O_NONBLOCK));
 assert(chiaki_socket_set_nonblock(pair[0], false) == CHIAKI_ERR_SUCCESS);
 assert(fcntl(pair[0], F_GETFL) == (before & ~O_NONBLOCK));
 assert(chiaki_socket_set_nonblock(-1, true) != CHIAKI_ERR_SUCCESS);
 close(pair[0]); close(pair[1]);
 puts("PASS: socket nonblocking mode, flag preservation and invalid-fd error");
}
''')
PY
xcrun --sdk macosx clang -Wall -Werror \
 -I"$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/Headers" \
 "$TEMP_DIR/test.c" -o "$TEMP_DIR/test"
"$TEMP_DIR/test"
