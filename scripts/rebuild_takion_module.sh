#!/bin/bash
# Rebuild takion.c for visionOS and update libchiaki_full.a.
#
# Why: the Takion DATA channel (reliable messages: heartbeat, rumble, pad info,
# trigger effects) uses a 16-entry reorder queue with the default END drop
# strategy. Once the console gives up retransmitting a lost data packet (seen
# after a multi-second stall), the queue head never fills, no DATA_ACK is ever
# sent and every later packet is dropped ("Takion dropping data with seq num ..."
# thousands of times) for the rest of the session. The vendored tree is read-only,
# so a copy of the COMMITTED upstream file is patched (never the working tree,
# which carries unrelated local edits):
#   1. Time-gated resync of the DATA reorder queue: END while the current head
#      has been missing for < 500 ms (the console is still retransmitting it;
#      a far packet is dropped and resent later, nothing is lost), BEGIN after
#      that (the console has given up on the head; the first packet >= begin+16
#      resyncs, the cumulative DATA_ACK goes out, the wedge ends).
#   2. SO_RCVBUF raised from 100 KB to 2 MB (non-fatal fallback to the original
#      value) so a consumer stall of about a second no longer loses datagrams.
#   3. Gestalt() (macOS-only, absent from the xros SDK) replaced by a fixed major
#      version 11: IP_DONTFRAG is supported on every visionOS kernel.
# The BEGIN branch of reorderqueue.c is exercised by nothing else in this library,
# so the script proves it on the host first.
#
# Same in-place `ar r` replacement as rebuild_holepunch_module.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
CHIAKI_DIR="$PROJECT_DIR/chiaki-ng"
LIB_PATH="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a"
HEADERS_DIR="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/Headers"
TEMP_DIR="$PROJECT_DIR/build-temp-takion"
# The anchors below were written against this chiaki-ng commit.
EXPECTED_HEAD=25f89d386caf20de099040344ecf6b84342acb3e

echo "=== Rebuilding takion module for visionOS ==="
SDK_PATH=$(xcrun --sdk xros --show-sdk-path)
CLANG=$(xcrun --sdk xros --find clang)
AR=$(xcrun --sdk xros --find ar)
HOST_CLANG=$(xcrun --sdk macosx --find clang)
HOST_SDK=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# --- 1. Prove the drop strategies on the host before shipping them -----------------
cat > "$TEMP_DIR/reorderqueue_begin_test.c" <<'C'
#include <chiaki/reorderqueue.h>
#include <stdio.h>
#include <stdlib.h>

static int drops = 0;
static void drop_cb(uint64_t seq_num, void *user, void *cb_user) { (void)seq_num; (void)user; (void)cb_user; drops++; }

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); return 1; } } while (0)

int main(void) {
  ChiakiReorderQueue q;
  uint64_t seq; void *user;

  /* Case A: hole at the head plus stored entries; a packet 16+ ahead must resync. */
  CHECK(chiaki_reorder_queue_init_32(&q, 4, 100) == CHIAKI_ERR_SUCCESS);
  chiaki_reorder_queue_set_drop_strategy(&q, CHIAKI_REORDER_QUEUE_DROP_STRATEGY_BEGIN);
  chiaki_reorder_queue_set_drop_cb(&q, drop_cb, NULL);
  for (uint64_t s = 101; s <= 105; s++) chiaki_reorder_queue_push(&q, s, (void *)(uintptr_t)s);
  CHECK(!chiaki_reorder_queue_pull(&q, &seq, &user)); /* head 100 missing */
  chiaki_reorder_queue_push(&q, 120, (void *)120);
  CHECK(q.begin == 105);
  CHECK(drops == 4);
  CHECK(chiaki_reorder_queue_pull(&q, &seq, &user) && seq == 105);
  CHECK(!chiaki_reorder_queue_pull(&q, &seq, &user)); /* 106 not received */
  chiaki_reorder_queue_fini(&q);

  /* Case B: empty queue with a stuck head; the next far packet must become the head. */
  drops = 0;
  CHECK(chiaki_reorder_queue_init_32(&q, 4, 200) == CHIAKI_ERR_SUCCESS);
  chiaki_reorder_queue_set_drop_strategy(&q, CHIAKI_REORDER_QUEUE_DROP_STRATEGY_BEGIN);
  chiaki_reorder_queue_set_drop_cb(&q, drop_cb, NULL);
  chiaki_reorder_queue_push(&q, 216, (void *)216);
  CHECK(q.begin == 216 && drops == 0);
  CHECK(chiaki_reorder_queue_pull(&q, &seq, &user) && seq == 216);
  chiaki_reorder_queue_fini(&q);

  /* Case C: the default END strategy really is the wedge (regression guard). */
  drops = 0;
  CHECK(chiaki_reorder_queue_init_32(&q, 4, 300) == CHIAKI_ERR_SUCCESS);
  chiaki_reorder_queue_set_drop_cb(&q, drop_cb, NULL);
  chiaki_reorder_queue_push(&q, 316, (void *)316);
  CHECK(q.begin == 300 && drops == 1);
  chiaki_reorder_queue_fini(&q);

  /* Case D: END while the head is young (far packet dropped, head kept for the
     retransmit, nothing lost), BEGIN once the gate expires (next far packet
     resyncs). Mirrors takion_data_stall_select_strategy() in the patched copy. */
  drops = 0;
  CHECK(chiaki_reorder_queue_init_32(&q, 4, 400) == CHIAKI_ERR_SUCCESS);
  chiaki_reorder_queue_set_drop_cb(&q, drop_cb, NULL);
  for (uint64_t s = 401; s <= 415; s++) chiaki_reorder_queue_push(&q, s, (void *)(uintptr_t)s);
  chiaki_reorder_queue_set_drop_strategy(&q, CHIAKI_REORDER_QUEUE_DROP_STRATEGY_END);
  chiaki_reorder_queue_push(&q, 416, (void *)416);
  CHECK(q.begin == 400 && drops == 1);               /* far packet dropped, head kept */
  chiaki_reorder_queue_push(&q, 400, (void *)400);   /* retransmitted head arrives */
  for (uint64_t s = 400; s <= 415; s++) CHECK(chiaki_reorder_queue_pull(&q, &seq, &user) && seq == s);
  CHECK(!chiaki_reorder_queue_pull(&q, &seq, &user) && q.count == 0);
  chiaki_reorder_queue_push(&q, 417, (void *)417);   /* 416 missing again: new hole */
  chiaki_reorder_queue_set_drop_strategy(&q, CHIAKI_REORDER_QUEUE_DROP_STRATEGY_BEGIN); /* gate expired */
  chiaki_reorder_queue_push(&q, 432, (void *)432);
  CHECK(q.begin == 417 && drops == 1);               /* only the unset head slot went */
  CHECK(chiaki_reorder_queue_pull(&q, &seq, &user) && seq == 417);
  chiaki_reorder_queue_fini(&q);

  printf("  reorder queue END/BEGIN strategies: OK\n");
  return 0;
}
C
"$HOST_CLANG" -isysroot "$HOST_SDK" -I"$CHIAKI_DIR/lib/include" -I"$HEADERS_DIR" -Wall -Wno-unused-parameter \
  "$TEMP_DIR/reorderqueue_begin_test.c" "$CHIAKI_DIR/lib/src/reorderqueue.c" -o "$TEMP_DIR/reorderqueue_begin_test"
"$TEMP_DIR/reorderqueue_begin_test"

# --- 2. Patch a COPY of the committed upstream source -------------------------------
ACTUAL_HEAD=$(git -C "$CHIAKI_DIR" rev-parse HEAD)
[ "$ACTUAL_HEAD" = "$EXPECTED_HEAD" ] || echo "  WARNING: chiaki-ng HEAD is $ACTUAL_HEAD, anchors were written against $EXPECTED_HEAD"
git -C "$CHIAKI_DIR" show HEAD:lib/src/takion.c > "$TEMP_DIR/takion.c"
python3 - "$TEMP_DIR/takion.c" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()

# 1. Time-gated drop strategy on the DATA reorder queue.
old_drop = "static void takion_data_drop(uint64_t seq_num, void *elem_user, void *cb_user)\n{\n"
new_drop = """/* visionOS: DATA reorder-queue drop policy.
   The console retransmits an unacked DATA seq for a bounded time, then gives up
   on it. With DROP_STRATEGY_END alone the queue then wedges forever (head never
   filled -> no pull -> no DATA_ACK -> every later packet dropped). With
   DROP_STRATEGY_BEGIN alone the first packet >= begin + 16 discards a head the
   console may still be about to retransmit, and the cumulative DATA_ACK that
   follows tells the console never to resend it. So: END while the current head
   has been missing for less than TAKION_DATA_STALL_RESYNC_US, BEGIN after that.
   File statics on purpose: ChiakiTakion is embedded by value in ChiakiSession,
   whose layout the app's ABI shim hard-codes, so it must not grow. The DATA
   path runs on the takion thread only; the reset at queue init keeps
   senkusha's instance from leaking state into the stream connection's. */
#define TAKION_DATA_STALL_RESYNC_US 500000
static uint64_t takion_data_stall_since_us = 0;
static uint64_t takion_data_stall_head = 0;

static void takion_data_stall_reset(void)
{
\ttakion_data_stall_since_us = 0;
\ttakion_data_stall_head = 0;
}

/* Call right after takion_flush_data_queue(): count > 0 there means the head
   is missing. Keyed to the head seq so a new hole does not inherit the age of
   the previous one. */
static void takion_data_stall_note(ChiakiTakion *takion)
{
\tif(chiaki_reorder_queue_count(&takion->data_queue) == 0)
\t{
\t\ttakion_data_stall_reset();
\t\treturn;
\t}
\tuint64_t head = takion->data_queue.begin;
\tif(takion_data_stall_since_us == 0 || takion_data_stall_head != head)
\t{
\t\ttakion_data_stall_head = head;
\t\ttakion_data_stall_since_us = chiaki_time_now_monotonic_us();
\t}
}

/* Call before chiaki_reorder_queue_push() so the first packet after the gate
   expires is the one that resyncs, not the one after it. */
static void takion_data_stall_select_strategy(ChiakiTakion *takion)
{
\tbool resync = takion_data_stall_since_us != 0
\t\t&& chiaki_time_now_monotonic_us() - takion_data_stall_since_us > TAKION_DATA_STALL_RESYNC_US;
\tchiaki_reorder_queue_set_drop_strategy(&takion->data_queue,
\t\t\tresync ? CHIAKI_REORDER_QUEUE_DROP_STRATEGY_BEGIN : CHIAKI_REORDER_QUEUE_DROP_STRATEGY_END);
}

""" + old_drop
assert s.count(old_drop) == 1, "takion_data_drop anchor"
s = s.replace(old_drop, new_drop)

old_cb = "\tchiaki_reorder_queue_set_drop_cb(&takion->data_queue, takion_data_drop, takion);\n"
new_cb = old_cb + "\ttakion_data_stall_reset(); /* visionOS: see takion_data_stall_* above */\n"
assert s.count(old_cb) == 1, "drop_cb anchor"
s = s.replace(old_cb, new_cb)

old_push = """\tchiaki_reorder_queue_push(&takion->data_queue, seq_num, entry);
\ttakion_flush_data_queue(takion);
}
"""
new_push = """\ttakion_data_stall_select_strategy(takion);
\tchiaki_reorder_queue_push(&takion->data_queue, seq_num, entry);
\ttakion_flush_data_queue(takion);
\ttakion_data_stall_note(takion);
}
"""
assert s.count(old_push) == 1, "data push anchor"
s = s.replace(old_push, new_push)

# 2. Larger socket receive buffer, non-fatal (both socket paths).
old_rcv = ("\t\tconst int rcvbuf_val = takion->a_rwnd;\n"
           "\t\tint r = setsockopt(takion->sock, SOL_SOCKET, SO_RCVBUF, (const CHIAKI_SOCKET_BUF_TYPE)&rcvbuf_val, sizeof(rcvbuf_val));\n")
new_rcv = """\t\t/* visionOS: absorb consumer stalls of about a second; the advertised
\t\t   a_rwnd on the wire is unchanged. Fall back to the upstream size rather
\t\t   than failing the connection if the kernel refuses the larger buffer. */
\t\tint rcvbuf_val = 2 * 1024 * 1024;
\t\tint r = setsockopt(takion->sock, SOL_SOCKET, SO_RCVBUF, (const CHIAKI_SOCKET_BUF_TYPE)&rcvbuf_val, sizeof(rcvbuf_val));
\t\tif(r < 0)
\t\t{
\t\t\trcvbuf_val = takion->a_rwnd;
\t\t\tr = setsockopt(takion->sock, SOL_SOCKET, SO_RCVBUF, (const CHIAKI_SOCKET_BUF_TYPE)&rcvbuf_val, sizeof(rcvbuf_val));
\t\t}
"""
assert s.count(old_rcv) == 2, "SO_RCVBUF anchors (expected both socket paths)"
s = s.replace(old_rcv, new_rcv)

# 3. Gestalt() is macOS-only; the two calls have different indentation, so anchor on the call.
old_gestalt = "Gestalt(gestaltSystemVersionMajor, &majorVersion);"
new_gestalt = "majorVersion = 11; /* visionOS: Gestalt is macOS-only; IP_DONTFRAG is supported */"
assert s.count(old_gestalt) == 2, "Gestalt anchors"
s = s.replace(old_gestalt, new_gestalt)
open(p, "w").write(s)
print("  applied time-gated DATA resync, SO_RCVBUF fallback and Gestalt removal to the temp copy")
PY

# --- 3. Compile for xros and replace the archive member in place --------------------
CFLAGS=(-target arm64-apple-xros2.0
        -isysroot "$SDK_PATH"
        -I"$CHIAKI_DIR/lib/include"
        -I"$HEADERS_DIR"
        -I"$CHIAKI_DIR/lib/src"
        -I"$CHIAKI_DIR/third-party/nanopb"
        -I"$CHIAKI_DIR/build-macos/lib/protobuf"
        -I"$PROJECT_DIR/mbedtls-src/include"
        -DCHIAKI_LIB_ENABLE_MBEDTLS=1
        -DCHIAKI_LIB_ENABLE_OPUS=1
        -O2
        -fPIC
        -Wall
        -Wno-unused-function)

echo "Compiling takion.c (patched copy of upstream HEAD)..."
"$CLANG" "${CFLAGS[@]}" -c "$TEMP_DIR/takion.c" -o "$TEMP_DIR/takion.c.o"
echo "  compiled"
nm "$TEMP_DIR/takion.c.o" | grep -q " T _chiaki_takion_connect$" || { echo "  ERROR: chiaki_takion_connect missing"; exit 1; }
if strings "$TEMP_DIR/takion.c.o" | grep -q "DSCP"; then
  echo "  ERROR: the DSCP block from the dirty working tree leaked into the object"; exit 1
fi

# Backup (never touch .orig / .backup, which merge_chiaki_opus.sh depends on)
if [ ! -f "${LIB_PATH}.pre-takion-reorder" ]; then
  cp "$LIB_PATH" "${LIB_PATH}.pre-takion-reorder"
  echo "  backup: libchiaki_full.a.pre-takion-reorder"
fi

# Replace only the takion member in place (extract-all + libtool drops same-basename members).
"$AR" r "$LIB_PATH" "$TEMP_DIR/takion.c.o"
"$(xcrun --sdk xros --find ranlib)" "$LIB_PATH"
echo "  replaced takion.c.o in libchiaki_full.a"
cd "$PROJECT_DIR"
rm -rf "$TEMP_DIR"
ls -la "$LIB_PATH"
echo "=== Done. Rebuild the Xcode project. ==="
