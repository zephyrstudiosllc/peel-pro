#ifndef PEEL_REMOTE_MICROPHONE_PRODUCER_AUTHENTICATION_H
#define PEEL_REMOTE_MICROPHONE_PRODUCER_AUTHENTICATION_H

#include <stdbool.h>
#include <sys/types.h>

/*
 * Non-realtime helpers. Authentication has no unsigned or ad-hoc fallback.
 * Process exit is considered verified only when the kernel reports ESRCH.
 */
bool peel_producer_authenticate_process(pid_t process_id);
bool peel_producer_process_has_exited(pid_t process_id);

#endif
