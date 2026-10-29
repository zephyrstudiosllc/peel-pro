#ifndef PEEL_REMOTE_MICROPHONE_PRODUCER_PROTOCOL_H
#define PEEL_REMOTE_MICROPHONE_PRODUCER_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * These selectors are published by the AudioServerPlugIn object. Each custom
 * property is marshalled by Core Audio as a CFPropertyListRef whose concrete
 * value must be CFData. The bytes inside that CFData use the layouts below.
 */
#define PEEL_PRODUCER_FOURCC(a, b, c, d) \
    ((((uint32_t)(a)) << 24u) | (((uint32_t)(b)) << 16u) | \
     (((uint32_t)(c)) << 8u) | ((uint32_t)(d)))

#define PEEL_PRODUCER_PROPERTY_BEGIN \
    PEEL_PRODUCER_FOURCC('p', 'b', 'e', 'g')
#define PEEL_PRODUCER_PROPERTY_END \
    PEEL_PRODUCER_FOURCC('p', 'e', 'n', 'd')
#define PEEL_PRODUCER_PROPERTY_PCM \
    PEEL_PRODUCER_FOURCC('p', 'p', 'c', 'm')
#define PEEL_PRODUCER_PROPERTY_STATUS \
    PEEL_PRODUCER_FOURCC('p', 's', 't', 's')

enum {
    PEEL_PRODUCER_PROTOCOL_VERSION = 1u,
    PEEL_PRODUCER_TOKEN_BYTES = 16u,
    PEEL_PRODUCER_SESSION_REQUEST_BYTES = 24u,
    PEEL_PRODUCER_PEAU_HEADER_BYTES = 36u,
    PEEL_PRODUCER_PCM_FRAME_COUNT = 960u,
    PEEL_PRODUCER_PCM_BYTES = 1920u,
    PEEL_PRODUCER_PEAU_PACKET_BYTES =
        PEEL_PRODUCER_PEAU_HEADER_BYTES + PEEL_PRODUCER_PCM_BYTES,
    PEEL_PRODUCER_PCM_REQUEST_BYTES =
        PEEL_PRODUCER_SESSION_REQUEST_BYTES +
        PEEL_PRODUCER_PEAU_PACKET_BYTES,
    PEEL_PRODUCER_STATUS_RESPONSE_BYTES = 40u
};

/*
 * Begin, end, and status qualifier (24 bytes):
 *   0...3   selector-specific ASCII magic: PPBG, PPEN, or PPST
 *   4       protocol version (1)
 *   5...7   zero
 *   8...23  caller-generated 128-bit session token
 *
 * PCM property data (1980 bytes):
 *   0...23  the same envelope using magic PPCM
 *   24...   one complete PEAU v1 client-to-Mac PCM packet
 *
 * Status property result (40 bytes; never contains the token):
 *   0...3   ASCII magic PPSR
 *   4       protocol version (1)
 *   5       PeelProducerSessionState
 *   6       PeelProducerPCMDisposition
 *   7       zero
 *   8...15  enqueued packet count, UInt64 big-endian
 *   16...23 waiting-discard packet count, UInt64 big-endian
 *   24...31 overflow-reject packet count, UInt64 big-endian
 *   32...39 sequence-reject packet count, UInt64 big-endian
 *
 * The PEAU header uses big-endian integers and must describe 960 mono 48 kHz
 * signed-16 little-endian frames. The parser decodes samples explicitly, so it
 * does not depend on host alignment or byte order.
 */

typedef enum PeelProducerProtocolResult {
    PEEL_PRODUCER_PROTOCOL_OK = 0,
    PEEL_PRODUCER_PROTOCOL_INVALID_ARGUMENT,
    PEEL_PRODUCER_PROTOCOL_INVALID_SIZE,
    PEEL_PRODUCER_PROTOCOL_INVALID_MAGIC,
    PEEL_PRODUCER_PROTOCOL_UNSUPPORTED_VERSION,
    PEEL_PRODUCER_PROTOCOL_NONZERO_RESERVED,
    PEEL_PRODUCER_PROTOCOL_ZERO_TOKEN,
    PEEL_PRODUCER_PROTOCOL_INVALID_PEAU_MAGIC,
    PEEL_PRODUCER_PROTOCOL_INVALID_PEAU_FIELDS,
    PEEL_PRODUCER_PROTOCOL_NEGATIVE_SAMPLE_TIME,
    PEEL_PRODUCER_PROTOCOL_SAMPLE_TIME_OVERFLOW
} PeelProducerProtocolResult;

typedef enum PeelProducerSessionState {
    PEEL_PRODUCER_SESSION_WAITING_FOR_CONSUMER = 1,
    PEEL_PRODUCER_SESSION_READY = 2
} PeelProducerSessionState;

typedef enum PeelProducerPCMDisposition {
    PEEL_PRODUCER_PCM_NONE = 0,
    PEEL_PRODUCER_PCM_ENQUEUED = 1,
    PEEL_PRODUCER_PCM_DISCARDED_WAITING = 2,
    PEEL_PRODUCER_PCM_REJECTED_OVERFLOW = 3,
    PEEL_PRODUCER_PCM_REJECTED_SEQUENCE = 4
} PeelProducerPCMDisposition;

typedef struct PeelProducerPCMRequest {
    uint8_t token[PEEL_PRODUCER_TOKEN_BYTES];
    uint64_t sequence;
    int64_t sample_time;
    int16_t frames[PEEL_PRODUCER_PCM_FRAME_COUNT];
} PeelProducerPCMRequest;

typedef struct PeelProducerStatusSnapshot {
    PeelProducerSessionState session_state;
    PeelProducerPCMDisposition last_disposition;
    uint64_t enqueued_packets;
    uint64_t discarded_waiting_packets;
    uint64_t rejected_overflow_packets;
    uint64_t rejected_sequence_packets;
} PeelProducerStatusSnapshot;

PeelProducerProtocolResult peel_producer_protocol_parse_begin(
    const uint8_t *bytes,
    size_t byte_count,
    uint8_t out_token[PEEL_PRODUCER_TOKEN_BYTES]
);

PeelProducerProtocolResult peel_producer_protocol_parse_end(
    const uint8_t *bytes,
    size_t byte_count,
    uint8_t out_token[PEEL_PRODUCER_TOKEN_BYTES]
);

PeelProducerProtocolResult peel_producer_protocol_parse_status_qualifier(
    const uint8_t *bytes,
    size_t byte_count,
    uint8_t out_token[PEEL_PRODUCER_TOKEN_BYTES]
);

PeelProducerProtocolResult peel_producer_protocol_parse_pcm(
    const uint8_t *bytes,
    size_t byte_count,
    PeelProducerPCMRequest *out_request
);

PeelProducerProtocolResult peel_producer_protocol_encode_status(
    const PeelProducerStatusSnapshot *snapshot,
    uint8_t out_bytes[PEEL_PRODUCER_STATUS_RESPONSE_BYTES]
);

/*
 * A session accepts its first sequence and thereafter requires strict
 * monotonic increase. Gaps are valid; duplicates and rewinds are rejected.
 */
bool peel_producer_protocol_sequence_is_new(
    bool has_previous_sequence,
    uint64_t previous_sequence,
    uint64_t candidate_sequence
);

#endif
