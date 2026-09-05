#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
#include <chiaki/time.h>
#include "feedbacksender.c"

static atomic_bool sending = false;
static atomic_bool block_network = true;
static atomic_int histories = 0;

ChiakiErrorCode chiaki_takion_send_feedback_state(ChiakiTakion *takion, ChiakiSeqNum16 seq, ChiakiFeedbackState *state) {
    atomic_store(&sending, true);
    // Bounded fake network stall, so a regression fails instead of hanging the test.
    for (int i = 0; i < 500 && atomic_load(&block_network); i++) usleep(1000);
    return CHIAKI_ERR_SUCCESS;
}
ChiakiErrorCode chiaki_takion_send_feedback_history(ChiakiTakion *takion, ChiakiSeqNum16 seq, uint8_t *buf, size_t size) {
    atomic_fetch_add(&histories, 1);
    return CHIAKI_ERR_SUCCESS;
}
void chiaki_log(ChiakiLog *log, ChiakiLogLevel level, const char *fmt, ...) {}

int main(void) {
    ChiakiFeedbackSender sender = {0};
    ChiakiTakion takion = {0};
    assert(chiaki_feedback_sender_init(&sender, &takion) == CHIAKI_ERR_SUCCESS);
    ChiakiControllerState state;
    chiaki_controller_state_set_idle(&state);
    state.left_x = 100;
    chiaki_feedback_sender_set_controller_state(&sender, &state);
    for (int i = 0; i < 1000 && !atomic_load(&sending); i++) usleep(1000);
    assert(atomic_load(&sending));
    uint64_t start = chiaki_time_now_monotonic_us();
    state.buttons = CHIAKI_CONTROLLER_BUTTON_CROSS;
    chiaki_feedback_sender_set_controller_state(&sender, &state);
    // Analog changes coalesce but never erase a pending button edge.
    for (int i = 0; i < 100; i++) {
        state.left_x++;
        chiaki_feedback_sender_set_controller_state(&sender, &state);
    }
    state.buttons = 0;
    chiaki_feedback_sender_set_controller_state(&sender, &state);
    uint64_t elapsed = chiaki_time_now_monotonic_us() - start;
    assert(elapsed < 100000); // must not wait for the 500 ms network stall
    chiaki_mutex_lock(&sender.state_mutex);
    assert(input_count == 2);
    assert(input_queue[input_head].buttons == CHIAKI_CONTROLLER_BUTTON_CROSS);
    assert(input_queue[(input_head + 1) % INPUT_QUEUE_CAPACITY].buttons == 0);
    chiaki_mutex_unlock(&sender.state_mutex);
    atomic_store(&block_network, false);
    for (int i = 0; i < 1000 && atomic_load(&histories) < 2; i++) usleep(1000);
    assert(atomic_load(&histories) == 2);
    chiaki_feedback_sender_fini(&sender);
    printf("PASS: input remains responsive during network stall (%llu us); press/release preserved\n", (unsigned long long)elapsed);
    return 0;
}
