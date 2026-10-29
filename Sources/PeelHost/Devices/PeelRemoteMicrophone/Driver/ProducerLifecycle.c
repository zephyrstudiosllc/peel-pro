#include "ProducerLifecycle.h"

#include <stddef.h>

void peel_producer_lifecycle_init(PeelProducerLifecycle *lifecycle) {
    if (lifecycle == NULL) {
        return;
    }
    atomic_init(&lifecycle->published_generation, 0u);
    atomic_init(&lifecycle->consumer_ready_generation, 0u);
}

bool peel_producer_lifecycle_publish(
    PeelProducerLifecycle *lifecycle,
    uint64_t generation
) {
    if (lifecycle == NULL || generation == 0u) {
        return false;
    }
    atomic_store_explicit(
        &lifecycle->published_generation,
        (unsigned long long)generation,
        memory_order_release
    );
    return true;
}

void peel_producer_lifecycle_invalidate(PeelProducerLifecycle *lifecycle) {
    if (lifecycle == NULL) {
        return;
    }
    atomic_store_explicit(
        &lifecycle->published_generation,
        0u,
        memory_order_release
    );
}

uint64_t peel_producer_lifecycle_published(
    const PeelProducerLifecycle *lifecycle
) {
    if (lifecycle == NULL) {
        return 0u;
    }
    return (uint64_t)atomic_load_explicit(
        &lifecycle->published_generation,
        memory_order_acquire
    );
}

uint64_t peel_producer_lifecycle_consumer_ready(
    const PeelProducerLifecycle *lifecycle
) {
    if (lifecycle == NULL) {
        return 0u;
    }
    return (uint64_t)atomic_load_explicit(
        &lifecycle->consumer_ready_generation,
        memory_order_acquire
    );
}

bool peel_producer_lifecycle_consumer_acknowledge(
    PeelProducerLifecycle *lifecycle,
    uint64_t drained_generation
) {
    if (lifecycle == NULL ||
        peel_producer_lifecycle_published(lifecycle) !=
            drained_generation) {
        return false;
    }

    atomic_store_explicit(
        &lifecycle->consumer_ready_generation,
        (unsigned long long)drained_generation,
        memory_order_release
    );
    return peel_producer_lifecycle_published(lifecycle) ==
        drained_generation;
}

bool peel_producer_lifecycle_session_is_ready(
    const PeelProducerLifecycle *lifecycle,
    uint64_t generation
) {
    if (lifecycle == NULL || generation == 0u) {
        return false;
    }
    const uint64_t publishedBefore =
        peel_producer_lifecycle_published(lifecycle);
    const uint64_t consumerReady =
        peel_producer_lifecycle_consumer_ready(lifecycle);
    const uint64_t publishedAfter =
        peel_producer_lifecycle_published(lifecycle);
    return publishedBefore == generation &&
        consumerReady == generation &&
        publishedAfter == generation;
}
