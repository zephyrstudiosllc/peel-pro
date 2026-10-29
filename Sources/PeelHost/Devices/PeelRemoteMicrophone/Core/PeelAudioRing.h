#ifndef PEEL_AUDIO_RING_H
#define PEEL_AUDIO_RING_H

#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#if ATOMIC_LLONG_LOCK_FREE != 2
#error "PeelAudioRing requires always-lock-free unsigned long long atomics"
#endif

#define PEEL_AUDIO_RING_SAMPLE_RATE_HZ 48000u
#define PEEL_AUDIO_RING_CHANNEL_COUNT 1u
/* Public logical capacity: 120 ms of mono audio. */
#define PEEL_AUDIO_RING_CAPACITY_FRAMES 5760u
/*
 * Implementation backing storage. Keep this power-of-two so a monotonic
 * unsigned-64-bit index maps to the same slot before and after counter rollover.
 * This is intentionally larger than the public logical capacity; callers must
 * continue to use PEEL_AUDIO_RING_CAPACITY_FRAMES for request and occupancy limits.
 */
#define PEEL_AUDIO_RING_STORAGE_FRAMES 8192u

#if (PEEL_AUDIO_RING_STORAGE_FRAMES & (PEEL_AUDIO_RING_STORAGE_FRAMES - 1u)) != 0u
#error "PeelAudioRing backing storage must be a power of two"
#endif

#if PEEL_AUDIO_RING_STORAGE_FRAMES < PEEL_AUDIO_RING_CAPACITY_FRAMES
#error "PeelAudioRing backing storage must cover logical capacity"
#endif

typedef enum PeelAudioRingStatus {
    PEEL_AUDIO_RING_OK = 0,
    PEEL_AUDIO_RING_OVERFLOW,
    PEEL_AUDIO_RING_UNDERRUN,
    PEEL_AUDIO_RING_INVALID_SIZE,
    PEEL_AUDIO_RING_INVALID_ARGUMENT,
    PEEL_AUDIO_RING_INVALID_STATE
} PeelAudioRingStatus;

typedef struct PeelAudioRingReadResult {
    PeelAudioRingStatus status;
    size_t frames_read;
} PeelAudioRingReadResult;

/*
 * Caller-owned fixed storage. Exactly one producer may call write and exactly one
 * consumer may call read. Do not access fields directly.
 */
typedef struct PeelAudioRing {
    atomic_ullong _consumer_index;
    atomic_ullong _producer_index;
    int16_t _frames[PEEL_AUDIO_RING_STORAGE_FRAMES];
} PeelAudioRing;

PeelAudioRingStatus peel_audio_ring_init(PeelAudioRing *ring);

/*
 * Resets an initialized ring to empty. The caller must guarantee that producer and
 * consumer are both quiescent; this function does not synchronize with either.
 */
PeelAudioRingStatus peel_audio_ring_reset_quiescent(PeelAudioRing *ring);

/*
 * Publishes all frame_count frames or none. A full/insufficient ring returns
 * PEEL_AUDIO_RING_OVERFLOW and does not modify either index or ring sample data.
 */
PeelAudioRingStatus peel_audio_ring_write(
    PeelAudioRing *ring,
    const int16_t *frames,
    size_t frame_count
);

/*
 * Reads up to frame_count frames and always initializes the complete output span.
 * Missing frames are signed-16 PCM silence. UNDERRUN reports the number of real
 * frames consumed in frames_read; silence is not added to the ring timeline.
 */
PeelAudioRingReadResult peel_audio_ring_read(
    PeelAudioRing *ring,
    int16_t *output,
    size_t frame_count
);

#ifdef PEEL_AUDIO_RING_TESTING
void peel_audio_ring_test_seed_empty_index(
    PeelAudioRing *ring,
    unsigned long long index
);
unsigned long long peel_audio_ring_test_consumer_index(const PeelAudioRing *ring);
unsigned long long peel_audio_ring_test_producer_index(const PeelAudioRing *ring);
#endif

#endif
