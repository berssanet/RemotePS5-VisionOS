"""Patch a pinned upstream copy, preserving ChiakiFeedbackSender's binary layout.
VisionRemotePS5 supports one active session; sidecar FIFO uses that sender's mutex.
"""
from pathlib import Path
import sys
p = Path(sys.argv[1]); s = p.read_text()
anchor = 'static void *feedback_sender_thread_func(void *user);'
s = s.replace(anchor, anchor + '''

/* Single active session, as enforced by ChiakiCore. Never extend the public ABI. */
#define INPUT_QUEUE_CAPACITY 256
static ChiakiControllerState input_queue[INPUT_QUEUE_CAPACITY];
static unsigned input_head, input_count, input_overflows;
static bool controller_state_equals_for_feedback_history(ChiakiControllerState *a, ChiakiControllerState *b);
''')
s = s.replace('\tfeedback_sender->log = takion->log;', '''\tinput_head = input_count = input_overflows = 0;
\tfeedback_sender->should_stop = false;
\tfeedback_sender->controller_state_changed = false;
\tfeedback_sender->log = takion->log;''')
s = s.replace('\tfeedback_sender->controller_state = *state;', '''\t/* Coalesce analog motion only when no button/trigger/touch edge is lost. */
\tif(input_count && controller_state_equals_for_feedback_history(
\t\t\t&input_queue[(input_head + input_count - 1) % INPUT_QUEUE_CAPACITY], state))
\t\tinput_queue[(input_head + input_count - 1) % INPUT_QUEUE_CAPACITY] = *state;
\telse
\t{
\t\tif(input_count == INPUT_QUEUE_CAPACITY)
\t\t{
\t\t\t/* Bounded overload: retain the latest state, including releases. */
\t\t\tinput_head = (input_head + 1) % INPUT_QUEUE_CAPACITY;
\t\t\tinput_count--;
\t\t\tinput_overflows++;
\t\t}
\t\tinput_queue[(input_head + input_count++) % INPUT_QUEUE_CAPACITY] = *state;
\t}
\tfeedback_sender->controller_state = *state;''')
s = s.replace('static void feedback_sender_send_state(ChiakiFeedbackSender *feedback_sender)', 'static void feedback_sender_send_state(ChiakiFeedbackSender *feedback_sender, ChiakiControllerState *snapshot)')
s = s.replace('feedback_sender->controller_state.', 'snapshot->')
s = s.replace('static void feedback_sender_send_history(ChiakiFeedbackSender *feedback_sender)', 'static void feedback_sender_send_history(ChiakiFeedbackSender *feedback_sender, ChiakiControllerState *snapshot)')
s = s.replace('ChiakiControllerState *state_now = &feedback_sender->controller_state;', 'ChiakiControllerState *state_now = snapshot;')
a=s.index('\t\tbool send_feedback_state = true;', s.index('static void *feedback_sender_thread_func(void *user)\n{'))
b=s.index('\n\t}\n\n\tchiaki_mutex_unlock',a)
s=s[:a]+'''\t\tbool changed = input_count > 0;
\t\tChiakiControllerState snapshot = feedback_sender->controller_state;
\t\tif(changed)
\t\t{
\t\t\tsnapshot = input_queue[input_head];
\t\t\tinput_head = (input_head + 1) % INPUT_QUEUE_CAPACITY;
\t\t\tinput_count--;
\t\t}
\t\tfeedback_sender->controller_state_changed = input_count > 0;
\t\tunsigned overflows = input_overflows;
\t\tinput_overflows = 0;
\t\t/* No socket operation, encryption or logging while holding the input mutex. */
\t\tchiaki_mutex_unlock(&feedback_sender->state_mutex);
\t\tif(overflows)
\t\t\tCHIAKI_LOGW(feedback_sender->log, "Input queue overflow: %u old states discarded", overflows);
\t\tif(!changed || !controller_state_equals_for_feedback_state(&snapshot, &feedback_sender->controller_state_prev))
\t\t\tfeedback_sender_send_state(feedback_sender, &snapshot);
\t\tif(changed && !controller_state_equals_for_feedback_history(&snapshot, &feedback_sender->controller_state_prev))
\t\t\tfeedback_sender_send_history(feedback_sender, &snapshot);
\t\tfeedback_sender->controller_state_prev = snapshot;
\t\tchiaki_mutex_lock(&feedback_sender->state_mutex);'''+s[b:]
assert 'feedback_sender_send_state(feedback_sender);' not in s
assert 'snapshot->' in s
p.write_text(s)
