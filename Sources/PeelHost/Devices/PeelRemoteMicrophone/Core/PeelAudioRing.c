#include "PeelAudioRing.h"

#include <string.h>

static size_t peel_audio_ring_min_size(size_t lhs, size_t rhs) {
    return lhs < rhs ? lhs : rhs;
}

static size_t peel_audio_ring_storage_position(unsigned long long index) {
    return (size_t)(index & (PEEL_AUDIO_RING_STORAGE_FRAMES - 1u));
}

PeelAudioRingStatus peel_audio_ring_init(PeelAudioRing *ring) {
    if (ring == NULL) {
        return PEEL_AUDIO_RING_INVALID_ARGUMENT;
    }

    atomic_init(&ring->_consumer_index, 0u);
    atomic_init(&ring->_producer_index, 0u);
    return PEEL_AUDIO_RING_OK;
}

PeelAudioRingStatus peel_audio_ring_reset_quiescent(PeelAudioRing *ring) {
    if (ring == NULL) {
        return PEEL_AUDIO_RING_INVALID_ARGUMENT;
    }

    atomic_store_explicit(&ring->_consumer_index, 0u, memory_order_relaxed);
    atomic_store_explicit(&ring->_producer_index, 0u, memory_order_relaxed);
    return PEEL_AUDIO_RING_OK;
}

PeelAudioRingStatus peel_audio_ring_write(
    PeelAudioRing *ring,
    const int16_t *frames,
    size_t frame_count
) {
    if (ring == NULL || frames == NULL) {
        return PEEL_AUDIO_RING_INVALID_ARGUMENT;
    }
    if (frame_count == 0u || frame_count > PEEL_AUDIO_RING_CAPACITY_FRAMES) {
        return PEEL_AUDIO_RING_INVALID_SIZE;
    }

    const unsigned long long producer = atomic_load_explicit(
        &ring->_producer_index,
        memory_order_relaxed
    );
    const unsigned long long consumer = atomic_load_explicit(
        &ring->_consumer_index,
        memory_order_acquire
    );
    const unsigned long long used = producer - consumer;

    if (used > PEEL_AUDIO_RING_CAPACITY_FRAMES) {
        return PEEL_AUDIO_RING_INVALID_STATE;
    }

    const size_t writable = PEEL_AUDIO_RING_CAPACITY_FRAMES - (size_t)used;
    if (frame_count > writable) {
        return PEEL_AUDIO_RING_OVERFLOW;
    }

    const size_t position = peel_audio_ring_storage_position(producer);
    const size_t first_count = peel_audio_ring_min_size(
        frame_count,
        PEEL_AUDIO_RING_STORAGE_FRAMES - position
    );
    const size_t second_count = frame_count - first_count;

    memcpy(
        &ring->_frames[position],
        frames,
        first_count * sizeof(frames[0])
    );
    if (second_count > 0u) {
        memcpy(
            &ring->_frames[0],
            &frames[first_count],
            second_count * sizeof(frames[0])
        );
    }

    atomic_store_explicit(
        &ring->_producer_index,
        producer + (unsigned long long)frame_count,
        memory_order_release
    );
    return PEEL_AUDIO_RING_OK;
}

PeelAudioRingReadResult peel_audio_ring_read(
    PeelAudioRing *ring,
    int16_t *output,
    size_t frame_count
) {
    PeelAudioRingReadResult result = {
        .status = PEEL_AUDIO_RING_OK,
        .frames_read = 0u
    };

    if (ring == NULL || output == NULL) {
        result.status = PEEL_AUDIO_RING_INVALID_ARGUMENT;
        return result;
    }
    if (frame_count == 0u || frame_count > PEEL_AUDIO_RING_CAPACITY_FRAMES) {
        result.status = PEEL_AUDIO_RING_INVALID_SIZE;
        return result;
    }

    const unsigned long long consumer = atomic_load_explicit(
        &ring->_consumer_index,
        memory_order_relaxed
    );
    const unsigned long long producer = atomic_load_explicit(
        &ring->_producer_index,
        memory_order_acquire
    );
    const unsigned long long readable = producer - consumer;

    if (readable > PEEL_AUDIO_RING_CAPACITY_FRAMES) {
        result.status = PEEL_AUDIO_RING_INVALID_STATE;
        return result;
    }

    result.frames_read = peel_audio_ring_min_size(
        frame_count,
        (size_t)readable
    );

    const size_t position = peel_audio_ring_storage_position(consumer);
    const size_t first_count = peel_audio_ring_min_size(
        result.frames_read,
        PEEL_AUDIO_RING_STORAGE_FRAMES - position
    );
    const size_t second_count = result.frames_read - first_count;

    memcpy(
        output,
        &ring->_frames[position],
        first_count * sizeof(output[0])
    );
    if (second_count > 0u) {
        memcpy(
            &output[first_count],
            &ring->_frames[0],
            second_count * sizeof(output[0])
        );
    }

    if (result.frames_read < frame_count) {
        memset(
            &output[result.frames_read],
            0,
            (frame_count - result.frames_read) * sizeof(output[0])
        );
        result.status = PEEL_AUDIO_RING_UNDERRUN;
    }

    atomic_store_explicit(
        &ring->_consumer_index,
        consumer + (unsigned long long)result.frames_read,
        memory_order_release
    );
    return result;
}

#ifdef PEEL_AUDIO_RING_TESTING
void peel_audio_ring_test_seed_empty_index(
    PeelAudioRing *ring,
    unsigned long long index
) {
    atomic_store_explicit(
        &ring->_consumer_index,
        index,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &ring->_producer_index,
        index,
        memory_order_relaxed
    );
}

unsigned long long peel_audio_ring_test_consumer_index(const PeelAudioRing *ring) {
    return atomic_load_explicit(
        &ring->_consumer_index,
        memory_order_relaxed
    );
}

unsigned long long peel_audio_ring_test_producer_index(const PeelAudioRing *ring) {
    return atomic_load_explicit(
        &ring->_producer_index,
        memory_order_relaxed
    );
}
#endif
