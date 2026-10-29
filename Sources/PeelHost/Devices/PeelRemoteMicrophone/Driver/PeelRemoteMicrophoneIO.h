#ifndef PEEL_REMOTE_MICROPHONE_IO_H
#define PEEL_REMOTE_MICROPHONE_IO_H

#include "../Core/PeelAudioRing.h"

#include <stddef.h>
#include <stdint.h>

typedef struct PeelRemoteMicrophoneRenderResult {
    PeelAudioRingStatus status;
    size_t frames_from_ring;
} PeelRemoteMicrophoneRenderResult;

/*
 * Consumes mono 48 kHz signed-16 frames and writes mono Float32 samples.
 * The caller supplies fixed scratch storage so this operation never allocates.
 */
PeelRemoteMicrophoneRenderResult peel_remote_microphone_render_float32(
    PeelAudioRing *ring,
    float *output,
    size_t frame_count,
    int16_t *scratch,
    size_t scratch_capacity
);

#endif
