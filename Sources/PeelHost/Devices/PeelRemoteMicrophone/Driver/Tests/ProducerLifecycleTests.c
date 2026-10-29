#include "../ProducerLifecycle.h"
#include "PeelAudioRing.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return false;                                                      \
        }                                                                      \
    } while (0)

static bool drain_ring_bounded(
    PeelAudioRing *ring,
    size_t *out_frames_drained
) {
    int16_t scratch[480];
    size_t frames_drained = 0u;
    for (size_t read_index = 0u; read_index < 12u; ++read_index) {
        const PeelAudioRingReadResult result =
            peel_audio_ring_read(ring, scratch, 480u);
        CHECK(
            result.status == PEEL_AUDIO_RING_OK ||
            result.status == PEEL_AUDIO_RING_UNDERRUN
        );
        frames_drained += result.frames_read;
        if (result.frames_read < 480u) {
            *out_frames_drained = frames_drained;
            return true;
        }
    }
    *out_frames_drained = frames_drained;
    return true;
}

static bool test_end_requires_consumer_barrier(void) {
    PeelProducerLifecycle lifecycle;
    peel_producer_lifecycle_init(&lifecycle);

    CHECK(peel_producer_lifecycle_publish(&lifecycle, 1u));
    CHECK(!peel_producer_lifecycle_session_is_ready(&lifecycle, 1u));
    CHECK(
        peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 1u)
    );
    CHECK(peel_producer_lifecycle_session_is_ready(&lifecycle, 1u));

    peel_producer_lifecycle_invalidate(&lifecycle);
    CHECK(peel_producer_lifecycle_published(&lifecycle) == 0u);
    CHECK(peel_producer_lifecycle_consumer_ready(&lifecycle) == 1u);
    CHECK(!peel_producer_lifecycle_session_is_ready(&lifecycle, 1u));
    CHECK(
        peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 0u)
    );
    CHECK(peel_producer_lifecycle_consumer_ready(&lifecycle) == 0u);
    return true;
}

static bool test_replacement_rejects_stale_acknowledgement(void) {
    PeelProducerLifecycle lifecycle;
    peel_producer_lifecycle_init(&lifecycle);

    CHECK(peel_producer_lifecycle_publish(&lifecycle, 7u));
    CHECK(
        peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 7u)
    );
    peel_producer_lifecycle_invalidate(&lifecycle);
    CHECK(peel_producer_lifecycle_publish(&lifecycle, 8u));

    CHECK(
        !peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 0u)
    );
    CHECK(
        !peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 7u)
    );
    CHECK(!peel_producer_lifecycle_session_is_ready(&lifecycle, 8u));
    CHECK(
        peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 8u)
    );
    CHECK(peel_producer_lifecycle_session_is_ready(&lifecycle, 8u));
    return true;
}

static bool test_generation_zero_never_publishes_as_session(void) {
    PeelProducerLifecycle lifecycle;
    peel_producer_lifecycle_init(&lifecycle);

    CHECK(!peel_producer_lifecycle_publish(&lifecycle, 0u));
    CHECK(peel_producer_lifecycle_published(&lifecycle) == 0u);
    CHECK(!peel_producer_lifecycle_session_is_ready(&lifecycle, 0u));
    CHECK(
        peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 0u)
    );
    CHECK(!peel_producer_lifecycle_session_is_ready(&lifecycle, 0u));
    return true;
}

static bool test_replacement_drains_old_ring_before_ready(void) {
    PeelProducerLifecycle lifecycle;
    PeelAudioRing ring;
    int16_t old_frames[960];
    int16_t new_frames[960];
    int16_t output[960];
    for (size_t index = 0u; index < 960u; ++index) {
        old_frames[index] = 111;
        new_frames[index] = 222;
    }

    peel_producer_lifecycle_init(&lifecycle);
    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(peel_producer_lifecycle_publish(&lifecycle, 41u));
    CHECK(
        peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 41u)
    );
    CHECK(peel_audio_ring_write(&ring, old_frames, 960u) ==
          PEEL_AUDIO_RING_OK);

    peel_producer_lifecycle_invalidate(&lifecycle);
    CHECK(peel_producer_lifecycle_publish(&lifecycle, 42u));
    CHECK(!peel_producer_lifecycle_session_is_ready(&lifecycle, 42u));

    size_t frames_drained = 0u;
    CHECK(drain_ring_bounded(&ring, &frames_drained));
    CHECK(frames_drained == 960u);
    CHECK(
        peel_producer_lifecycle_consumer_acknowledge(&lifecycle, 42u)
    );
    CHECK(peel_producer_lifecycle_session_is_ready(&lifecycle, 42u));

    CHECK(peel_audio_ring_write(&ring, new_frames, 960u) ==
          PEEL_AUDIO_RING_OK);
    const PeelAudioRingReadResult read_result =
        peel_audio_ring_read(&ring, output, 960u);
    CHECK(read_result.status == PEEL_AUDIO_RING_OK);
    CHECK(read_result.frames_read == 960u);
    for (size_t index = 0u; index < 960u; ++index) {
        CHECK(output[index] == 222);
    }
    return true;
}

int main(void) {
    const bool passed =
        test_end_requires_consumer_barrier() &&
        test_replacement_rejects_stale_acknowledgement() &&
        test_generation_zero_never_publishes_as_session() &&
        test_replacement_drains_old_ring_before_ready();
    if (!passed) {
        return 1;
    }
    puts("ProducerLifecycle tests passed");
    return 0;
}
