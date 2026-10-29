#include "../ProducerProtocol.h"

#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return false;                                                      \
        }                                                                      \
    } while (0)

static void write_u16_be(uint16_t value, uint8_t *bytes) {
    bytes[0] = (uint8_t)(value >> 8u);
    bytes[1] = (uint8_t)(value & 0xffu);
}

static void write_u32_be(uint32_t value, uint8_t *bytes) {
    bytes[0] = (uint8_t)(value >> 24u);
    bytes[1] = (uint8_t)((value >> 16u) & 0xffu);
    bytes[2] = (uint8_t)((value >> 8u) & 0xffu);
    bytes[3] = (uint8_t)(value & 0xffu);
}

static void write_u64_be(uint64_t value, uint8_t *bytes) {
    for (size_t index = 0u; index < 8u; ++index) {
        bytes[index] =
            (uint8_t)(value >> ((7u - index) * 8u));
    }
}

static uint64_t read_u64_be(const uint8_t *bytes) {
    uint64_t value = 0u;
    for (size_t index = 0u; index < 8u; ++index) {
        value = (value << 8u) | bytes[index];
    }
    return value;
}

static void fill_token(uint8_t token[PEEL_PRODUCER_TOKEN_BYTES]) {
    for (size_t index = 0u; index < PEEL_PRODUCER_TOKEN_BYTES; ++index) {
        token[index] = (uint8_t)(index + 1u);
    }
}

static void make_session_fixture(
    uint8_t bytes[PEEL_PRODUCER_SESSION_REQUEST_BYTES],
    const char magic[4]
) {
    memset(bytes, 0, PEEL_PRODUCER_SESSION_REQUEST_BYTES);
    memcpy(bytes, magic, 4u);
    bytes[4] = PEEL_PRODUCER_PROTOCOL_VERSION;
    fill_token(&bytes[8]);
}

static void make_pcm_fixture(
    uint8_t bytes[PEEL_PRODUCER_PCM_REQUEST_BYTES]
) {
    memset(bytes, 0, PEEL_PRODUCER_PCM_REQUEST_BYTES);
    memcpy(bytes, "PPCM", 4u);
    bytes[4] = PEEL_PRODUCER_PROTOCOL_VERSION;
    fill_token(&bytes[8]);

    uint8_t *packet = &bytes[PEEL_PRODUCER_SESSION_REQUEST_BYTES];
    memcpy(packet, "PEAU", 4u);
    packet[4] = 1u;
    packet[5] = 1u;
    packet[6] = 1u;
    packet[7] = 0u;
    write_u32_be(PEEL_PRODUCER_PCM_BYTES, &packet[8]);
    write_u64_be(UINT64_C(0x0102030405060708), &packet[12]);
    write_u64_be(UINT64_C(960), &packet[20]);
    write_u32_be(48000u, &packet[28]);
    write_u16_be(PEEL_PRODUCER_PCM_FRAME_COUNT, &packet[32]);
    packet[34] = 1u;
    packet[35] = 2u;

    uint8_t *payload = &packet[PEEL_PRODUCER_PEAU_HEADER_BYTES];
    payload[0] = 0x00u;
    payload[1] = 0x80u;
    payload[2] = 0x00u;
    payload[3] = 0xc0u;
    payload[4] = 0x00u;
    payload[5] = 0x00u;
    payload[6] = 0x00u;
    payload[7] = 0x40u;
    payload[8] = 0xffu;
    payload[9] = 0x7fu;
}

static bool test_selectors_are_fixed(void) {
    CHECK(PEEL_PRODUCER_PROPERTY_BEGIN == UINT32_C(0x70626567));
    CHECK(PEEL_PRODUCER_PROPERTY_END == UINT32_C(0x70656e64));
    CHECK(PEEL_PRODUCER_PROPERTY_PCM == UINT32_C(0x7070636d));
    CHECK(PEEL_PRODUCER_PROPERTY_STATUS == UINT32_C(0x70737473));
    return true;
}

static bool test_session_envelopes(void) {
    uint8_t bytes[PEEL_PRODUCER_SESSION_REQUEST_BYTES];
    uint8_t token[PEEL_PRODUCER_TOKEN_BYTES];

    make_session_fixture(bytes, "PPBG");
    CHECK(
        peel_producer_protocol_parse_begin(bytes, sizeof(bytes), token) ==
        PEEL_PRODUCER_PROTOCOL_OK
    );
    CHECK(memcmp(token, &bytes[8], sizeof(token)) == 0);

    make_session_fixture(bytes, "PPEN");
    CHECK(
        peel_producer_protocol_parse_end(bytes, sizeof(bytes), token) ==
        PEEL_PRODUCER_PROTOCOL_OK
    );
    make_session_fixture(bytes, "PPST");
    CHECK(
        peel_producer_protocol_parse_status_qualifier(
            bytes,
            sizeof(bytes),
            token
        ) == PEEL_PRODUCER_PROTOCOL_OK
    );

    CHECK(
        peel_producer_protocol_parse_begin(
            bytes,
            sizeof(bytes) - 1u,
            token
        ) == PEEL_PRODUCER_PROTOCOL_INVALID_SIZE
    );
    make_session_fixture(bytes, "PPBG");
    bytes[0] = 0u;
    CHECK(
        peel_producer_protocol_parse_begin(bytes, sizeof(bytes), token) ==
        PEEL_PRODUCER_PROTOCOL_INVALID_MAGIC
    );
    make_session_fixture(bytes, "PPBG");
    bytes[4] = 2u;
    CHECK(
        peel_producer_protocol_parse_begin(bytes, sizeof(bytes), token) ==
        PEEL_PRODUCER_PROTOCOL_UNSUPPORTED_VERSION
    );
    make_session_fixture(bytes, "PPBG");
    bytes[7] = 1u;
    CHECK(
        peel_producer_protocol_parse_begin(bytes, sizeof(bytes), token) ==
        PEEL_PRODUCER_PROTOCOL_NONZERO_RESERVED
    );
    make_session_fixture(bytes, "PPBG");
    memset(&bytes[8], 0, PEEL_PRODUCER_TOKEN_BYTES);
    CHECK(
        peel_producer_protocol_parse_begin(bytes, sizeof(bytes), token) ==
        PEEL_PRODUCER_PROTOCOL_ZERO_TOKEN
    );
    return true;
}

static bool test_pcm_fixture_and_endianness(void) {
    uint8_t bytes[PEEL_PRODUCER_PCM_REQUEST_BYTES];
    PeelProducerPCMRequest request;
    make_pcm_fixture(bytes);

    CHECK(
        peel_producer_protocol_parse_pcm(bytes, sizeof(bytes), &request) ==
        PEEL_PRODUCER_PROTOCOL_OK
    );
    CHECK(request.sequence == UINT64_C(0x0102030405060708));
    CHECK(request.sample_time == 960);
    CHECK(request.frames[0] == INT16_MIN);
    CHECK(request.frames[1] == -16384);
    CHECK(request.frames[2] == 0);
    CHECK(request.frames[3] == 16384);
    CHECK(request.frames[4] == INT16_MAX);
    CHECK(memcmp(request.token, &bytes[8], sizeof(request.token)) == 0);
    return true;
}

static bool test_pcm_rejections(void) {
    uint8_t bytes[PEEL_PRODUCER_PCM_REQUEST_BYTES];
    PeelProducerPCMRequest request;

    make_pcm_fixture(bytes);
    bytes[PEEL_PRODUCER_SESSION_REQUEST_BYTES] = 0u;
    CHECK(
        peel_producer_protocol_parse_pcm(bytes, sizeof(bytes), &request) ==
        PEEL_PRODUCER_PROTOCOL_INVALID_PEAU_MAGIC
    );

    const size_t field_offsets[] = {4u, 5u, 6u, 7u, 28u, 32u, 34u, 35u};
    for (size_t index = 0u;
         index < sizeof(field_offsets) / sizeof(field_offsets[0]);
         ++index) {
        make_pcm_fixture(bytes);
        bytes[
            PEEL_PRODUCER_SESSION_REQUEST_BYTES + field_offsets[index]
        ] ^= 1u;
        CHECK(
            peel_producer_protocol_parse_pcm(bytes, sizeof(bytes), &request) ==
            PEEL_PRODUCER_PROTOCOL_INVALID_PEAU_FIELDS
        );
    }

    make_pcm_fixture(bytes);
    bytes[PEEL_PRODUCER_SESSION_REQUEST_BYTES + 8u] = 1u;
    CHECK(
        peel_producer_protocol_parse_pcm(bytes, sizeof(bytes), &request) ==
        PEEL_PRODUCER_PROTOCOL_INVALID_PEAU_FIELDS
    );

    make_pcm_fixture(bytes);
    write_u64_be(
        UINT64_C(0x8000000000000000),
        &bytes[PEEL_PRODUCER_SESSION_REQUEST_BYTES + 20u]
    );
    CHECK(
        peel_producer_protocol_parse_pcm(bytes, sizeof(bytes), &request) ==
        PEEL_PRODUCER_PROTOCOL_NEGATIVE_SAMPLE_TIME
    );

    make_pcm_fixture(bytes);
    write_u64_be(
        (uint64_t)INT64_MAX - PEEL_PRODUCER_PCM_FRAME_COUNT + 1u,
        &bytes[PEEL_PRODUCER_SESSION_REQUEST_BYTES + 20u]
    );
    CHECK(
        peel_producer_protocol_parse_pcm(bytes, sizeof(bytes), &request) ==
        PEEL_PRODUCER_PROTOCOL_SAMPLE_TIME_OVERFLOW
    );

    CHECK(
        peel_producer_protocol_parse_pcm(
            bytes,
            sizeof(bytes) - 1u,
            &request
        ) == PEEL_PRODUCER_PROTOCOL_INVALID_SIZE
    );
    return true;
}

static bool test_sequence_policy(void) {
    CHECK(peel_producer_protocol_sequence_is_new(false, UINT64_MAX, 0u));
    CHECK(peel_producer_protocol_sequence_is_new(true, 9u, 10u));
    CHECK(!peel_producer_protocol_sequence_is_new(true, 9u, 9u));
    CHECK(!peel_producer_protocol_sequence_is_new(true, 9u, 8u));
    CHECK(!peel_producer_protocol_sequence_is_new(true, UINT64_MAX, 0u));
    return true;
}

static bool test_status_fixture(void) {
    const PeelProducerStatusSnapshot snapshot = {
        .session_state = PEEL_PRODUCER_SESSION_WAITING_FOR_CONSUMER,
        .last_disposition = PEEL_PRODUCER_PCM_DISCARDED_WAITING,
        .enqueued_packets = 1u,
        .discarded_waiting_packets = 2u,
        .rejected_overflow_packets = 3u,
        .rejected_sequence_packets = UINT64_C(0x0102030405060708)
    };
    uint8_t bytes[PEEL_PRODUCER_STATUS_RESPONSE_BYTES];
    CHECK(
        peel_producer_protocol_encode_status(&snapshot, bytes) ==
        PEEL_PRODUCER_PROTOCOL_OK
    );
    CHECK(memcmp(bytes, "PPSR", 4u) == 0);
    CHECK(bytes[4] == 1u);
    CHECK(bytes[5] == PEEL_PRODUCER_SESSION_WAITING_FOR_CONSUMER);
    CHECK(bytes[6] == PEEL_PRODUCER_PCM_DISCARDED_WAITING);
    CHECK(bytes[7] == 0u);
    CHECK(read_u64_be(&bytes[8]) == 1u);
    CHECK(read_u64_be(&bytes[16]) == 2u);
    CHECK(read_u64_be(&bytes[24]) == 3u);
    CHECK(
        read_u64_be(&bytes[32]) == UINT64_C(0x0102030405060708)
    );
    return true;
}

int main(void) {
    const bool passed =
        test_selectors_are_fixed() &&
        test_session_envelopes() &&
        test_pcm_fixture_and_endianness() &&
        test_pcm_rejections() &&
        test_sequence_policy() &&
        test_status_fixture();
    if (!passed) {
        return 1;
    }
    puts("ProducerProtocol tests passed");
    return 0;
}
