#ifndef PEEL_REMOTE_MICROPHONE_PRODUCER_LIFECYCLE_H
#define PEEL_REMOTE_MICROPHONE_PRODUCER_LIFECYCLE_H

#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

#if ATOMIC_LLONG_LOCK_FREE != 2
#error "ProducerLifecycle requires always-lock-free generation atomics"
#endif

typedef struct PeelProducerLifecycle {
    atomic_ullong published_generation;
    atomic_ullong consumer_ready_generation;
} PeelProducerLifecycle;

void peel_producer_lifecycle_init(PeelProducerLifecycle *lifecycle);

/*
 * Control-path publication. Generation zero means no producer session.
 * Publishing a nonzero replacement does not make it ready for enqueue until
 * the ring consumer acknowledges that generation after its bounded drain.
 */
bool peel_producer_lifecycle_publish(
    PeelProducerLifecycle *lifecycle,
    uint64_t generation
);
void peel_producer_lifecycle_invalidate(PeelProducerLifecycle *lifecycle);

uint64_t peel_producer_lifecycle_published(
    const PeelProducerLifecycle *lifecycle
);
uint64_t peel_producer_lifecycle_consumer_ready(
    const PeelProducerLifecycle *lifecycle
);

/*
 * Called only by the ring consumer after old data is drained and no old
 * producer write is in flight. A concurrent publication makes the
 * acknowledgement stale and leaves the new generation gated.
 */
bool peel_producer_lifecycle_consumer_acknowledge(
    PeelProducerLifecycle *lifecycle,
    uint64_t drained_generation
);

bool peel_producer_lifecycle_session_is_ready(
    const PeelProducerLifecycle *lifecycle,
    uint64_t generation
);

#endif
