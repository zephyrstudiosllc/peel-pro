#include "ProducerProtocol.h"

#include <limits.h>
#include <stdbool.h>
#include <string.h>

static const uint8_t kPeelBeginMagic[4] = {'P', 'P', 'B', 'G'};
static const uint8_t kPeelEndMagic[4] = {'P', 'P', 'E', 'N'};
static const uint8_t kPeelPCMMagic[4] = {'P', 'P', 'C', 'M'};
static const uint8_t kPeelStatusMagic[4] = {'P', 'P', 'S', 'T'};
static const uint8_t kPeelStatusResponseMagic[4] = {'P', 'P', 'S', 'R'};
static const uint8_t kPeelPEAUMagic[4] = {'P', 'E', 'A', 'U'};

static uint16_t peel_read_u16_be(const uint8_t *bytes) {
    return (uint16_t)(((uint16_t)bytes[0] << 8u) | (uint16_t)bytes[1]);
}

static uint32_t peel_read_u32_be(const uint8_t *bytes) {
    uint32_t value = 0u;
    for (size_t index = 0u; index < 4u; ++index) {
        value = (value << 8u) | (uint32_t)bytes[index];
    }
    return value;
}

static uint64_t peel_read_u64_be(const uint8_t *bytes) {
    uint64_t value = 0u;
    for (size_t index = 0u; index < 8u; ++index) {
        value = (value << 8u) | (uint64_t)bytes[index];
    }
    return value;
}

static int16_t peel_read_i16_le(const uint8_t *bytes) {
    const uint16_t value =
        (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8u);
    return (int16_t)value;
}

static void peel_write_u64_be(uint64_t value, uint8_t *bytes) {
    for (size_t index = 0u; index < 8u; ++index) {
        const size_t shift = (7u - index) * 8u;
        bytes[index] = (uint8_t)((value >> shift) & 0xffu);
    }
}

static bool peel_token_is_nonzero(
    const uint8_t token[PEEL_PRODUCER_TOKEN_BYTES]
) {
    uint8_t combined = 0u;
    for (size_t index = 0u; index < PEEL_PRODUCER_TOKEN_BYTES; ++index) {
        combined |= token[index];
    }
    return combined != 0u;
}

static PeelProducerProtocolResult peel_parse_envelope(
    const uint8_t *bytes,
    size_t byte_count,
    size_t expected_byte_count,
    const uint8_t expected_magic[4],
    uint8_t out_token[PEEL_PRODUCER_TOKEN_BYTES]
) {
    if (bytes == NULL || expected_magic == NULL || out_token == NULL) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_ARGUMENT;
    }
    if (byte_count != expected_byte_count) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_SIZE;
    }
    if (memcmp(bytes, expected_magic, 4u) != 0) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_MAGIC;
    }
    if (bytes[4] != PEEL_PRODUCER_PROTOCOL_VERSION) {
        return PEEL_PRODUCER_PROTOCOL_UNSUPPORTED_VERSION;
    }
    if (bytes[5] != 0u || bytes[6] != 0u || bytes[7] != 0u) {
        return PEEL_PRODUCER_PROTOCOL_NONZERO_RESERVED;
    }
    if (!peel_token_is_nonzero(&bytes[8])) {
        return PEEL_PRODUCER_PROTOCOL_ZERO_TOKEN;
    }

    memcpy(out_token, &bytes[8], PEEL_PRODUCER_TOKEN_BYTES);
    return PEEL_PRODUCER_PROTOCOL_OK;
}

PeelProducerProtocolResult peel_producer_protocol_parse_begin(
    const uint8_t *bytes,
    size_t byte_count,
    uint8_t out_token[PEEL_PRODUCER_TOKEN_BYTES]
) {
    return peel_parse_envelope(
        bytes,
        byte_count,
        PEEL_PRODUCER_SESSION_REQUEST_BYTES,
        kPeelBeginMagic,
        out_token
    );
}

PeelProducerProtocolResult peel_producer_protocol_parse_end(
    const uint8_t *bytes,
    size_t byte_count,
    uint8_t out_token[PEEL_PRODUCER_TOKEN_BYTES]
) {
    return peel_parse_envelope(
        bytes,
        byte_count,
        PEEL_PRODUCER_SESSION_REQUEST_BYTES,
        kPeelEndMagic,
        out_token
    );
}

PeelProducerProtocolResult peel_producer_protocol_parse_status_qualifier(
    const uint8_t *bytes,
    size_t byte_count,
    uint8_t out_token[PEEL_PRODUCER_TOKEN_BYTES]
) {
    return peel_parse_envelope(
        bytes,
        byte_count,
        PEEL_PRODUCER_SESSION_REQUEST_BYTES,
        kPeelStatusMagic,
        out_token
    );
}

PeelProducerProtocolResult peel_producer_protocol_parse_pcm(
    const uint8_t *bytes,
    size_t byte_count,
    PeelProducerPCMRequest *out_request
) {
    if (bytes == NULL || out_request == NULL) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_ARGUMENT;
    }

    uint8_t token[PEEL_PRODUCER_TOKEN_BYTES];
    PeelProducerProtocolResult result = peel_parse_envelope(
        bytes,
        byte_count,
        PEEL_PRODUCER_PCM_REQUEST_BYTES,
        kPeelPCMMagic,
        token
    );
    if (result != PEEL_PRODUCER_PROTOCOL_OK) {
        return result;
    }

    const uint8_t *packet = &bytes[PEEL_PRODUCER_SESSION_REQUEST_BYTES];
    if (memcmp(packet, kPeelPEAUMagic, 4u) != 0) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_PEAU_MAGIC;
    }
    if (packet[4] != 1u ||
        packet[5] != 1u ||
        packet[6] != 1u ||
        packet[7] != 0u ||
        peel_read_u32_be(&packet[8]) != PEEL_PRODUCER_PCM_BYTES ||
        peel_read_u32_be(&packet[28]) != 48000u ||
        peel_read_u16_be(&packet[32]) != PEEL_PRODUCER_PCM_FRAME_COUNT ||
        packet[34] != 1u ||
        packet[35] != 2u) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_PEAU_FIELDS;
    }

    const uint64_t raw_sample_time = peel_read_u64_be(&packet[20]);
    if (raw_sample_time > (uint64_t)INT64_MAX) {
        return PEEL_PRODUCER_PROTOCOL_NEGATIVE_SAMPLE_TIME;
    }
    if (raw_sample_time >
        (uint64_t)INT64_MAX - PEEL_PRODUCER_PCM_FRAME_COUNT) {
        return PEEL_PRODUCER_PROTOCOL_SAMPLE_TIME_OVERFLOW;
    }

    memcpy(out_request->token, token, PEEL_PRODUCER_TOKEN_BYTES);
    out_request->sequence = peel_read_u64_be(&packet[12]);
    out_request->sample_time = (int64_t)raw_sample_time;
    const uint8_t *payload = &packet[PEEL_PRODUCER_PEAU_HEADER_BYTES];
    for (size_t index = 0u;
         index < PEEL_PRODUCER_PCM_FRAME_COUNT;
         ++index) {
        out_request->frames[index] =
            peel_read_i16_le(&payload[index * 2u]);
    }
    return PEEL_PRODUCER_PROTOCOL_OK;
}

PeelProducerProtocolResult peel_producer_protocol_encode_status(
    const PeelProducerStatusSnapshot *snapshot,
    uint8_t out_bytes[PEEL_PRODUCER_STATUS_RESPONSE_BYTES]
) {
    if (snapshot == NULL || out_bytes == NULL) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_ARGUMENT;
    }
    if (snapshot->session_state !=
            PEEL_PRODUCER_SESSION_WAITING_FOR_CONSUMER &&
        snapshot->session_state != PEEL_PRODUCER_SESSION_READY) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_ARGUMENT;
    }
    if (snapshot->last_disposition < PEEL_PRODUCER_PCM_NONE ||
        snapshot->last_disposition > PEEL_PRODUCER_PCM_REJECTED_SEQUENCE) {
        return PEEL_PRODUCER_PROTOCOL_INVALID_ARGUMENT;
    }

    memset(out_bytes, 0, PEEL_PRODUCER_STATUS_RESPONSE_BYTES);
    memcpy(out_bytes, kPeelStatusResponseMagic, 4u);
    out_bytes[4] = PEEL_PRODUCER_PROTOCOL_VERSION;
    out_bytes[5] = (uint8_t)snapshot->session_state;
    out_bytes[6] = (uint8_t)snapshot->last_disposition;
    peel_write_u64_be(snapshot->enqueued_packets, &out_bytes[8]);
    peel_write_u64_be(snapshot->discarded_waiting_packets, &out_bytes[16]);
    peel_write_u64_be(snapshot->rejected_overflow_packets, &out_bytes[24]);
    peel_write_u64_be(snapshot->rejected_sequence_packets, &out_bytes[32]);
    return PEEL_PRODUCER_PROTOCOL_OK;
}

bool peel_producer_protocol_sequence_is_new(
    bool has_previous_sequence,
    uint64_t previous_sequence,
    uint64_t candidate_sequence
) {
    return !has_previous_sequence || candidate_sequence > previous_sequence;
}
