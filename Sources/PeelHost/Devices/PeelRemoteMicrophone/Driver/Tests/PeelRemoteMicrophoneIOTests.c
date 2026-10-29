#include "../PeelRemoteMicrophoneIO.h"

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return false;                                                      \
        }                                                                      \
    } while (0)

static bool floats_are_close(float lhs, float rhs) {
    return fabsf(lhs - rhs) <= 0.000001f;
}

static bool test_signed16_conversion(void) {
    PeelAudioRing ring;
    int16_t scratch[8];
    float output[5];
    const int16_t input[] = {INT16_MIN, -16384, 0, 16384, INT16_MAX};

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(
        peel_audio_ring_write(&ring, input, 5u) ==
        PEEL_AUDIO_RING_OK
    );

    const PeelRemoteMicrophoneRenderResult result =
        peel_remote_microphone_render_float32(
            &ring,
            output,
            5u,
            scratch,
            8u
        );

    CHECK(result.status == PEEL_AUDIO_RING_OK);
    CHECK(result.frames_from_ring == 5u);
    CHECK(floats_are_close(output[0], -1.0f));
    CHECK(floats_are_close(output[1], -0.5f));
    CHECK(floats_are_close(output[2], 0.0f));
    CHECK(floats_are_close(output[3], 0.5f));
    CHECK(floats_are_close(output[4], 32767.0f / 32768.0f));
    return true;
}

static bool test_partial_underrun_is_silence(void) {
    PeelAudioRing ring;
    int16_t scratch[4];
    float output[] = {9.0f, 9.0f, 9.0f, 9.0f};
    const int16_t input[] = {8192, -8192};

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(
        peel_audio_ring_write(&ring, input, 2u) ==
        PEEL_AUDIO_RING_OK
    );

    const PeelRemoteMicrophoneRenderResult result =
        peel_remote_microphone_render_float32(
            &ring,
            output,
            4u,
            scratch,
            4u
        );

    CHECK(result.status == PEEL_AUDIO_RING_UNDERRUN);
    CHECK(result.frames_from_ring == 2u);
    CHECK(floats_are_close(output[0], 0.25f));
    CHECK(floats_are_close(output[1], -0.25f));
    CHECK(floats_are_close(output[2], 0.0f));
    CHECK(floats_are_close(output[3], 0.0f));
    return true;
}

static bool test_empty_underrun_is_silence(void) {
    PeelAudioRing ring;
    int16_t scratch[3];
    float output[] = {9.0f, 9.0f, 9.0f};

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);

    const PeelRemoteMicrophoneRenderResult result =
        peel_remote_microphone_render_float32(
            &ring,
            output,
            3u,
            scratch,
            3u
        );

    CHECK(result.status == PEEL_AUDIO_RING_UNDERRUN);
    CHECK(result.frames_from_ring == 0u);
    for (size_t index = 0u; index < 3u; ++index) {
        CHECK(floats_are_close(output[index], 0.0f));
    }
    return true;
}

static bool test_large_render_uses_bounded_scratch(void) {
    PeelAudioRing ring;
    int16_t scratch[7];
    int16_t input[31];
    float output[31];

    for (size_t index = 0u; index < 31u; ++index) {
        input[index] = (int16_t)(index * 101u);
    }

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);
    CHECK(
        peel_audio_ring_write(&ring, input, 31u) ==
        PEEL_AUDIO_RING_OK
    );

    const PeelRemoteMicrophoneRenderResult result =
        peel_remote_microphone_render_float32(
            &ring,
            output,
            31u,
            scratch,
            7u
        );

    CHECK(result.status == PEEL_AUDIO_RING_OK);
    CHECK(result.frames_from_ring == 31u);
    for (size_t index = 0u; index < 31u; ++index) {
        CHECK(
            floats_are_close(
                output[index],
                (float)input[index] / 32768.0f
            )
        );
    }
    return true;
}

static bool test_invalid_arguments_do_not_touch_output(void) {
    PeelAudioRing ring;
    int16_t scratch[2];
    float output[] = {4.0f, 5.0f};

    CHECK(peel_audio_ring_init(&ring) == PEEL_AUDIO_RING_OK);

    PeelRemoteMicrophoneRenderResult result =
        peel_remote_microphone_render_float32(
            NULL,
            output,
            2u,
            scratch,
            2u
        );
    CHECK(result.status == PEEL_AUDIO_RING_INVALID_ARGUMENT);
    CHECK(floats_are_close(output[0], 4.0f));
    CHECK(floats_are_close(output[1], 5.0f));

    result = peel_remote_microphone_render_float32(
        &ring,
        output,
        2u,
        scratch,
        0u
    );
    CHECK(result.status == PEEL_AUDIO_RING_INVALID_SIZE);
    CHECK(floats_are_close(output[0], 4.0f));
    CHECK(floats_are_close(output[1], 5.0f));
    return true;
}

int main(void) {
    const bool passed =
        test_signed16_conversion() &&
        test_partial_underrun_is_silence() &&
        test_empty_underrun_is_silence() &&
        test_large_render_uses_bounded_scratch() &&
        test_invalid_arguments_do_not_touch_output();

    if (!passed) {
        return EXIT_FAILURE;
    }

    puts("PeelRemoteMicrophoneIOTests: PASS");
    return EXIT_SUCCESS;
}
