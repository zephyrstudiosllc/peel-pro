#include "PeelAudioRing.h"

#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expression)                                                        \
    do {                                                                         \
        if (!(expression)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expression); \
            return 0;                                                            \
        }                                                                        \
    } while (0)

static void fill_sequence(int16_t *frames, size_t count, int16_t first) {
    for (size_t index = 0u; index < count; ++index) {
        frames[index] = (int16_t)(first + (int16_t)index);
    }
}

static int test_capacity_and_wrap(void) {
    PeelAudioRing ring;
    int16_t input[PEEL_AUDIO_RING_CAPACITY_FRAMES];
    int16_t output[PEEL_AUDIO_RING_CAPACITY_FRAMES];
    fill_sequence(input, PEEL_AUDIO_RING_CAPACITY_FRAMES, -2000);

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(
        peel_audio_ring_write(
            &ring,
            input,
            PEEL_AUDIO_RING_CAPACITY_FRAMES
        ) == PEEL_AUDIO_RING_OK
    );

    PeelAudioRingReadResult result = peel_audio_ring_read(
        &ring,
        output,
        PEEL_AUDIO_RING_CAPACITY_FRAMES
    );
    CHECK(result.status == PEEL_AUDIO_RING_OK);
    CHECK(result.frames_read == PEEL_AUDIO_RING_CAPACITY_FRAMES);
    CHECK(memcmp(input, output, sizeof(input)) == 0);

    const unsigned long long storage_wrap_start =
        PEEL_AUDIO_RING_CAPACITY_FRAMES - 40u;
    int16_t storage_wrap_input[128];
    int16_t storage_wrap_output[128];
    fill_sequence(storage_wrap_input, 128u, 2000);
    peel_audio_ring_test_seed_empty_index(&ring, storage_wrap_start);

    CHECK(
        peel_audio_ring_write(&ring, storage_wrap_input, 128u)
            == PEEL_AUDIO_RING_OK
    );
    result = peel_audio_ring_read(&ring, storage_wrap_output, 128u);
    CHECK(result.status == PEEL_AUDIO_RING_OK);
    CHECK(result.frames_read == 128u);
    CHECK(
        memcmp(
            storage_wrap_input,
            storage_wrap_output,
            sizeof(storage_wrap_input)
        ) == 0
    );

    const unsigned long long start = ULLONG_MAX - 100u;
    int16_t wrap_input[256];
    int16_t wrap_output[256];
    fill_sequence(wrap_input, 256u, 3000);
    peel_audio_ring_test_seed_empty_index(&ring, start);

    CHECK(peel_audio_ring_write(&ring, wrap_input, 256u) == PEEL_AUDIO_RING_OK);
    result = peel_audio_ring_read(&ring, wrap_output, 256u);
    CHECK(result.status == PEEL_AUDIO_RING_OK);
    CHECK(result.frames_read == 256u);
    CHECK(memcmp(wrap_input, wrap_output, sizeof(wrap_input)) == 0);
    CHECK(
        peel_audio_ring_test_consumer_index(&ring)
            == start + (unsigned long long)256u
    );
    CHECK(
        peel_audio_ring_test_producer_index(&ring)
            == start + (unsigned long long)256u
    );
    return 1;
}

static int test_staggered_counter_rollover(void) {
    PeelAudioRing ring;
    int16_t first[16];
    int16_t second[16];
    int16_t output[24];
    int16_t prefix[8];
    const unsigned long long start = ULLONG_MAX - 8u;

    fill_sequence(first, 16u, 4000);
    fill_sequence(second, 16u, 5000);

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    peel_audio_ring_test_seed_empty_index(&ring, start);

    CHECK(peel_audio_ring_write(&ring, first, 16u) == PEEL_AUDIO_RING_OK);
    PeelAudioRingReadResult result = peel_audio_ring_read(&ring, prefix, 8u);
    CHECK(result.status == PEEL_AUDIO_RING_OK);
    CHECK(result.frames_read == 8u);
    CHECK(memcmp(prefix, first, sizeof(prefix)) == 0);
    CHECK(peel_audio_ring_test_consumer_index(&ring) == ULLONG_MAX);
    CHECK(peel_audio_ring_test_producer_index(&ring) == 7u);

    CHECK(peel_audio_ring_write(&ring, second, 16u) == PEEL_AUDIO_RING_OK);
    result = peel_audio_ring_read(&ring, output, 24u);
    CHECK(result.status == PEEL_AUDIO_RING_OK);
    CHECK(result.frames_read == 24u);
    CHECK(memcmp(output, &first[8], sizeof(first) - sizeof(prefix)) == 0);
    CHECK(memcmp(&output[8], second, sizeof(second)) == 0);
    CHECK(
        peel_audio_ring_test_consumer_index(&ring)
            == start + (unsigned long long)32u
    );
    CHECK(
        peel_audio_ring_test_producer_index(&ring)
            == start + (unsigned long long)32u
    );
    return 1;
}

static int test_reject_new_overflow(void) {
    PeelAudioRing ring;
    int16_t original[PEEL_AUDIO_RING_CAPACITY_FRAMES];
    int16_t output[PEEL_AUDIO_RING_CAPACITY_FRAMES];
    const int16_t rejected = 12345;
    fill_sequence(original, PEEL_AUDIO_RING_CAPACITY_FRAMES, -3000);

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(
        peel_audio_ring_write(
            &ring,
            original,
            PEEL_AUDIO_RING_CAPACITY_FRAMES
        ) == PEEL_AUDIO_RING_OK
    );

    const unsigned long long consumer_before =
        peel_audio_ring_test_consumer_index(&ring);
    const unsigned long long producer_before =
        peel_audio_ring_test_producer_index(&ring);

    CHECK(
        peel_audio_ring_write(&ring, &rejected, 1u)
            == PEEL_AUDIO_RING_OVERFLOW
    );
    CHECK(peel_audio_ring_test_consumer_index(&ring) == consumer_before);
    CHECK(peel_audio_ring_test_producer_index(&ring) == producer_before);

    const PeelAudioRingReadResult result = peel_audio_ring_read(
        &ring,
        output,
        PEEL_AUDIO_RING_CAPACITY_FRAMES
    );
    CHECK(result.status == PEEL_AUDIO_RING_OK);
    CHECK(result.frames_read == PEEL_AUDIO_RING_CAPACITY_FRAMES);
    CHECK(memcmp(original, output, sizeof(original)) == 0);
    return 1;
}

static int test_underrun_silence(void) {
    PeelAudioRing ring;
    const int16_t input[3] = { -7, 11, 29 };
    int16_t output[8];

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(peel_audio_ring_write(&ring, input, 3u) == PEEL_AUDIO_RING_OK);
    memset(output, 0x7f, sizeof(output));

    PeelAudioRingReadResult result = peel_audio_ring_read(&ring, output, 8u);
    CHECK(result.status == PEEL_AUDIO_RING_UNDERRUN);
    CHECK(result.frames_read == 3u);
    CHECK(memcmp(input, output, sizeof(input)) == 0);
    for (size_t index = 3u; index < 8u; ++index) {
        CHECK(output[index] == 0);
    }

    memset(output, 0x7f, sizeof(output));
    result = peel_audio_ring_read(&ring, output, 8u);
    CHECK(result.status == PEEL_AUDIO_RING_UNDERRUN);
    CHECK(result.frames_read == 0u);
    for (size_t index = 0u; index < 8u; ++index) {
        CHECK(output[index] == 0);
    }
    return 1;
}

static int test_invalid_sizes_and_arguments(void) {
    PeelAudioRing ring;
    int16_t frame = 42;
    int16_t output[2] = { 111, 222 };

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    const unsigned long long consumer_before =
        peel_audio_ring_test_consumer_index(&ring);
    const unsigned long long producer_before =
        peel_audio_ring_test_producer_index(&ring);

    CHECK(
        peel_audio_ring_write(&ring, &frame, 0u)
            == PEEL_AUDIO_RING_INVALID_SIZE
    );
    CHECK(
        peel_audio_ring_write(
            &ring,
            &frame,
            PEEL_AUDIO_RING_CAPACITY_FRAMES + 1u
        ) == PEEL_AUDIO_RING_INVALID_SIZE
    );
    CHECK(
        peel_audio_ring_read(&ring, output, 0u).status
            == PEEL_AUDIO_RING_INVALID_SIZE
    );
    CHECK(
        peel_audio_ring_read(
            &ring,
            output,
            PEEL_AUDIO_RING_CAPACITY_FRAMES + 1u
        ).status == PEEL_AUDIO_RING_INVALID_SIZE
    );
    CHECK(output[0] == 111 && output[1] == 222);
    CHECK(peel_audio_ring_test_consumer_index(&ring) == consumer_before);
    CHECK(peel_audio_ring_test_producer_index(&ring) == producer_before);

    CHECK(peel_audio_ring_init(NULL) == PEEL_AUDIO_RING_INVALID_ARGUMENT);
    CHECK(
        peel_audio_ring_write(NULL, &frame, 1u)
            == PEEL_AUDIO_RING_INVALID_ARGUMENT
    );
    CHECK(
        peel_audio_ring_write(&ring, NULL, 1u)
            == PEEL_AUDIO_RING_INVALID_ARGUMENT
    );
    CHECK(
        peel_audio_ring_read(NULL, output, 1u).status
            == PEEL_AUDIO_RING_INVALID_ARGUMENT
    );
    CHECK(
        peel_audio_ring_read(&ring, NULL, 1u).status
            == PEEL_AUDIO_RING_INVALID_ARGUMENT
    );
    return 1;
}

static int test_quiescent_reset(void) {
    PeelAudioRing ring;
    const int16_t input[4] = { 1, 2, 3, 4 };
    int16_t output[4] = { 9, 9, 9, 9 };

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(peel_audio_ring_write(&ring, input, 4u) == PEEL_AUDIO_RING_OK);
    CHECK(peel_audio_ring_reset_quiescent(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(peel_audio_ring_test_consumer_index(&ring) == 0u);
    CHECK(peel_audio_ring_test_producer_index(&ring) == 0u);

    const PeelAudioRingReadResult result = peel_audio_ring_read(
        &ring,
        output,
        4u
    );
    CHECK(result.status == PEEL_AUDIO_RING_UNDERRUN);
    CHECK(result.frames_read == 0u);
    for (size_t index = 0u; index < 4u; ++index) {
        CHECK(output[index] == 0);
    }
    return 1;
}

enum {
    CONCURRENT_TOTAL_FRAMES = 500000,
    PRODUCER_CHUNK_LIMIT = 127,
    CONSUMER_CHUNK_LIMIT = 131
};

typedef struct ConcurrencyContext {
    PeelAudioRing ring;
    atomic_int failed;
} ConcurrencyContext;

static int16_t concurrent_sample(size_t index) {
    const int16_t magnitude = (int16_t)((index % 30000u) + 1u);
    return (index & 1u) == 0u ? magnitude : (int16_t)-magnitude;
}

static void *producer_thread(void *opaque_context) {
    ConcurrencyContext *context = (ConcurrencyContext *)opaque_context;
    int16_t frames[PRODUCER_CHUNK_LIMIT];
    size_t produced = 0u;

    while (produced < CONCURRENT_TOTAL_FRAMES) {
        if (atomic_load_explicit(&context->failed, memory_order_relaxed) != 0) {
            return NULL;
        }

        size_t count = ((produced * 17u) % PRODUCER_CHUNK_LIMIT) + 1u;
        if (count > CONCURRENT_TOTAL_FRAMES - produced) {
            count = CONCURRENT_TOTAL_FRAMES - produced;
        }
        for (size_t index = 0u; index < count; ++index) {
            frames[index] = concurrent_sample(produced + index);
        }

        const PeelAudioRingStatus status = peel_audio_ring_write(
            &context->ring,
            frames,
            count
        );
        if (status == PEEL_AUDIO_RING_OK) {
            produced += count;
        } else if (status == PEEL_AUDIO_RING_OVERFLOW) {
            sched_yield();
        } else {
            atomic_store_explicit(&context->failed, 1, memory_order_relaxed);
            return NULL;
        }
    }
    return NULL;
}

static void *consumer_thread(void *opaque_context) {
    ConcurrencyContext *context = (ConcurrencyContext *)opaque_context;
    int16_t output[CONSUMER_CHUNK_LIMIT];
    size_t consumed = 0u;

    while (consumed < CONCURRENT_TOTAL_FRAMES) {
        if (atomic_load_explicit(&context->failed, memory_order_relaxed) != 0) {
            return NULL;
        }

        size_t requested = ((consumed * 29u) % CONSUMER_CHUNK_LIMIT) + 1u;
        if (requested > CONCURRENT_TOTAL_FRAMES - consumed) {
            requested = CONCURRENT_TOTAL_FRAMES - consumed;
        }

        const PeelAudioRingReadResult result = peel_audio_ring_read(
            &context->ring,
            output,
            requested
        );
        if (result.status != PEEL_AUDIO_RING_OK
            && result.status != PEEL_AUDIO_RING_UNDERRUN) {
            atomic_store_explicit(&context->failed, 1, memory_order_relaxed);
            return NULL;
        }

        for (size_t index = 0u; index < result.frames_read; ++index) {
            if (output[index] != concurrent_sample(consumed + index)) {
                atomic_store_explicit(&context->failed, 1, memory_order_relaxed);
                return NULL;
            }
        }
        for (size_t index = result.frames_read; index < requested; ++index) {
            if (output[index] != 0) {
                atomic_store_explicit(&context->failed, 1, memory_order_relaxed);
                return NULL;
            }
        }

        consumed += result.frames_read;
        if (result.frames_read == 0u) {
            sched_yield();
        }
    }
    return NULL;
}

static int test_concurrent_spsc(void) {
    ConcurrencyContext context;
    pthread_t producer;
    pthread_t consumer;

    CHECK(peel_audio_ring_init(&context.ring) == PEEL_AUDIO_RING_OK);
    atomic_init(&context.failed, 0);
    CHECK(pthread_create(&producer, NULL, producer_thread, &context) == 0);
    if (pthread_create(&consumer, NULL, consumer_thread, &context) != 0) {
        atomic_store_explicit(&context.failed, 1, memory_order_relaxed);
        CHECK(pthread_join(producer, NULL) == 0);
        CHECK(0);
    }

    CHECK(pthread_join(producer, NULL) == 0);
    CHECK(pthread_join(consumer, NULL) == 0);
    CHECK(atomic_load_explicit(&context.failed, memory_order_relaxed) == 0);
    return 1;
}

int main(void) {
    if (!test_capacity_and_wrap()
        || !test_staggered_counter_rollover()
        || !test_reject_new_overflow()
        || !test_underrun_silence()
        || !test_invalid_sizes_and_arguments()
        || !test_quiescent_reset()
        || !test_concurrent_spsc()) {
        return 1;
    }

    puts("PeelAudioRing tests passed");
    return 0;
}
