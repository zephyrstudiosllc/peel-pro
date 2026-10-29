#ifndef PEEL_REMOTE_MICROPHONE_PRODUCER_H
#define PEEL_REMOTE_MICROPHONE_PRODUCER_H

#include "../Core/PeelAudioRing.h"

#include <stddef.h>
#include <stdint.h>

/*
 * Internal bridge used by the authenticated custom-property control path.
 * These hidden functions do not create or expose IPC themselves.
 *
 * A nonzero I/O generation is valid only while one HAL client owns input I/O.
 * The session generation must also be consumer-ready. Each property submission
 * obtains the I/O generation immediately before enqueue; producer sessions are
 * intentionally independent of HAL I/O lifetime.
 */
uint64_t peel_remote_microphone_driver_producer_generation(void);

PeelAudioRingStatus peel_remote_microphone_driver_enqueue_frames(
    uint64_t io_generation,
    uint64_t producer_session_generation,
    const int16_t *frames,
    size_t frame_count
);

#endif
