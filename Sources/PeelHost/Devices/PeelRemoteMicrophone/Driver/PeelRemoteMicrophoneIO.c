#include "PeelRemoteMicrophoneIO.h"

#include <string.h>

static size_t peel_remote_microphone_min_size(size_t lhs, size_t rhs) {
    return lhs < rhs ? lhs : rhs;
}

PeelRemoteMicrophoneRenderResult peel_remote_microphone_render_float32(
    PeelAudioRing *ring,
    float *output,
    size_t frame_count,
    int16_t *scratch,
    size_t scratch_capacity
) {
    PeelRemoteMicrophoneRenderResult result = {
        .status = PEEL_AUDIO_RING_OK,
        .frames_from_ring = 0u
    };

    if (ring == NULL || output == NULL || scratch == NULL) {
        result.status = PEEL_AUDIO_RING_INVALID_ARGUMENT;
        return result;
    }
    if (scratch_capacity == 0u ||
        scratch_capacity > PEEL_AUDIO_RING_CAPACITY_FRAMES) {
        result.status = PEEL_AUDIO_RING_INVALID_SIZE;
        return result;
    }

    size_t offset = 0u;
    while (offset < frame_count) {
        const size_t chunk_size = peel_remote_microphone_min_size(
            frame_count - offset,
            scratch_capacity
        );
        const PeelAudioRingReadResult read_result = peel_audio_ring_read(
            ring,
            scratch,
            chunk_size
        );

        if (read_result.status != PEEL_AUDIO_RING_OK &&
            read_result.status != PEEL_AUDIO_RING_UNDERRUN) {
            memset(
                &output[offset],
                0,
                (frame_count - offset) * sizeof(output[0])
            );
            result.status = read_result.status;
            return result;
        }

        for (size_t index = 0u; index < chunk_size; ++index) {
            output[offset + index] = (float)scratch[index] / 32768.0f;
        }

        result.frames_from_ring += read_result.frames_read;
        if (read_result.status == PEEL_AUDIO_RING_UNDERRUN) {
            result.status = PEEL_AUDIO_RING_UNDERRUN;
        }
        offset += chunk_size;
    }

    return result;
}
