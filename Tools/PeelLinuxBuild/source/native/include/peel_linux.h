#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* UI callbacks are synchronous GTK-main-thread calls; return promptly. Copy all
 * arguments before queuing managed work. No key/PIN is passed through argv. */
typedef void (*PeelConnect)(const char *stable_id, const char *address, int port, void *user);
typedef void (*PeelOpenWindow)(uint32_t window_id, uint64_t session_generation, void *user);
typedef void (*PeelDisconnect)(void *user);
typedef void (*PeelCloseWindow)(uint32_t window_id, uint64_t session_generation, void *user);
int peel_linux_run(PeelConnect connect, PeelOpenWindow open_window, PeelDisconnect disconnect, PeelCloseWindow close_window, void *user);
void peel_linux_status(const char *message);
void peel_linux_windows(const char *rows_json, uint64_t session_generation); /* exact current authenticated list */
/* Additive host UI: register before run; callbacks are synchronous on GTK.
 * event:1 activated,2 Pair,3 Share,4 Stop,5 preclose. answer:0 cancel,
 *1 visible Pair / explicit Share approval,2 Stop after approval.
 * A preclose callback MUST drain asynchronously and finish on the live context. */
typedef void (*PeelHostUIEvent)(int event, uint64_t epoch, void *user);
typedef void (*PeelHostUIAnswer)(uint64_t operation, int answer, void *user);
void peel_linux_host_ui_register(PeelHostUIEvent event, PeelHostUIAnswer answer, void *user);
void peel_linux_host_ui_state(uint64_t epoch, uint64_t revision, const char *message, int can_pair, int can_share, int can_stop);
int peel_linux_host_ui_present(uint64_t epoch, uint64_t operation, int kind, const char *name, const char *detail);
void peel_linux_host_ui_dismiss(uint64_t epoch, uint64_t operation);
void peel_linux_host_ui_finish_close(uint64_t epoch);
/* Discovery callback:0 unavailable/lost,1 established,2 fully retired.
 * Delegates remain rooted until2;1 is NOT TLS/media authority. */
typedef void (*PeelDiscoveryResult)(uint64_t operation, int state, void *user);
int peel_linux_discovery_publish(uint64_t operation, const char *name, const char *type, uint16_t port, int interface_index, int protocol, const char *txt_json, PeelDiscoveryResult result, void *user);
int peel_linux_discovery_update(uint64_t operation, uint64_t transaction, const char *txt_json, PeelDiscoveryResult result, void *user);
void peel_linux_discovery_stop(uint64_t operation);
/* Decoder ownership: one native receiver handle per current TLS video socket.
 * configure accepts Annex-B SPS/PPS; push accepts Annex-B AU, neither is Peel wire.
 * Existing managed PeelBinaryPacketReader is the ONLY packet parser. */
void peel_linux_receiver_generation(uint64_t generation); /* fences old decoder/UI before replacement */
void *peel_linux_decoder_new(uint64_t generation, uint32_t window_id);
int peel_linux_decoder_configure(void *decoder, uint32_t width, uint32_t height, const uint8_t *parameters, size_t length);
int peel_linux_decoder_push(void *decoder, const uint8_t *access_unit, size_t length, uint64_t pts_ns, uint64_t duration_ns);
void peel_linux_decoder_free(void *decoder); /* closes pipeline, fences pending UI */
/* Native host seam: every observer/snapshot/start/stop call must run while owning
 * the default GLib main context. A managed adapter must marshal, never block it
 * on socket I/O. This is not a listener, advertisement or remote-input grant. */
typedef struct {
    uint64_t source_generation; /* exact live portal grant, 0 means inactive */
    uint32_t source_id; /* opaque 1, meaningful ONLY with source_generation */
    uint32_t width, height; /* actual first/current BGRA caps, 0 until known */
    uint32_t source_kind; /* portal source_type if supplied; otherwise 0 */
    int32_t active;
} PeelCaptureInfo;
typedef void (*PeelCaptureChanged)(const PeelCaptureInfo *capture, void *user);
int peel_linux_host_observe(PeelCaptureChanged changed, void *user);
int peel_linux_host_get_capture(PeelCaptureInfo *capture);
int peel_linux_h264_encoder_available(void); /* actual required factories only */
typedef struct {
    uint64_t source_generation, encoder_generation, configuration_generation;
    uint32_t source_id, width, height, timescale;
    int64_t pts_ns, duration_ns; /* GStreamer stream time, NOT physical latency */
    int32_t keyframe, configuration_changed;
    const uint8_t *avcc; size_t avcc_length; /* 4-byte big-endian NAL lengths */
    const uint8_t *sps; size_t sps_length;
    const uint8_t *pps; size_t pps_length;
} PeelEncodedFrame;
/* Borrowed bytes live ONLY during this callback on GTK main. Return 1 only if
 * all needed config/frame bytes were copied into a bounded immediate queue.
 * Return 0 for backpressure; dependent frames are withheld until a fresh IDR.
 * No callback may retain pointers or wait for a network operation. */
typedef int (*PeelEncodedSink)(const PeelEncodedFrame *frame, void *user);
typedef void (*PeelEncoderFailed)(uint64_t source_generation, uint64_t encoder_generation, void *user);
/* Start seeds exactly one latest actual sample of this grant/caps, even if no
 * later damage arrives. No timestamps are invented. One retained raw sample is
 * <=128 MiB and is released on source close/reselection or replaced on new caps.
 * Explicit keyframe request may replay the same real PTS. A strict-increasing
 * consumer must use a NEW encoder generation for static-content recovery. */
uint64_t peel_linux_host_encoder_start(uint64_t source_generation,
    uint32_t bitrate_bps, uint32_t gop_frames, PeelEncodedSink sink,
    PeelEncoderFailed failed, void *user);
int peel_linux_host_encoder_stop(uint64_t source_generation, uint64_t encoder_generation);
int peel_linux_host_encoder_request_keyframe(uint64_t source_generation, uint64_t encoder_generation);
/* Exact stop/revoke closes admission and drops queued bytes synchronously before
 * pipeline drain; no sink/failure callback can occur after stop returns. Keep
 * encoder callbacks/user alive until exact stop; observer user until unregister. */
/* Receiver playback of the streamed source's audio. Never a microphone or Voice
 * path. Managed AudioPacketReader is the ONLY PEAU parser; native accepts only
 * 20 ms S16LE 48 kHz interleaved stereo PCM (3840 bytes) into appsrc ->
 * audioconvert -> audioresample -> autoaudiosink. No GTK calls and no bus watch
 * on the default context: any non-GTK thread may call these. One handle per
 * current source owner; that owner serializes push/free and never pushes after
 * free. Available means the factories exist AND autoaudiosink reached READY on a
 * real audio sink; its fakesink no-output fallback counts as unavailable. */
int peel_linux_audio_available(void); /* only after peel_linux_run's gst_init */
void *peel_linux_audio_new(uint64_t receiver_generation); /* NULL: stale or no output */
int peel_linux_audio_push(void *audio, const uint8_t *pcm, size_t length); /* 1 queued; 0 dropped at the 200 ms bound; -1 failed/stale, free it */
void peel_linux_audio_free(void *audio); /* immediate stop; queued PCM is dropped */
/* Viewer toolbar for the streamed SOURCE: Listen (receiver playback of source
 * audio), source mute/volume, source previous/play-pause/next. Callbacks are
 * synchronous GTK-main calls carrying the viewer's exact window and receiver
 * generation; settings commands carry window 0. Return promptly. Nothing here
 * changes receiver OS volume or media sessions. */
enum {
    PEEL_VIEWER_LISTEN_ON = 1, PEEL_VIEWER_LISTEN_OFF = 2,
    PEEL_VIEWER_PLAY_PAUSE = 3, PEEL_VIEWER_PREVIOUS = 4, PEEL_VIEWER_NEXT = 5,
    PEEL_VIEWER_VOLUME_QUERY = 6, PEEL_VIEWER_VOLUME_SET = 7, PEEL_VIEWER_MUTE_SET = 8,
    PEEL_VIEWER_SHOW_VOLUME = 9, PEEL_VIEWER_SHOW_MEDIA = 10, PEEL_VIEWER_SHOWN = 11
};
enum { PEEL_AUDIO_UNAVAILABLE = 0, PEEL_AUDIO_OFF = 1, PEEL_AUDIO_IDLE = 2, PEEL_AUDIO_STARTING = 3, PEEL_AUDIO_PLAYING = 4, PEEL_AUDIO_FAILED = 5 };
typedef struct {
    int32_t audio; /* PEEL_AUDIO_*; PLAYING only after actual PCM was admitted */
    int32_t listen_enabled; /* the Listen toggle can act */
    int32_t media_enabled; /* source advertised source-media-keys-v1 for this current stream */
    int32_t volume_supported, can_set_volume, can_set_mute; /* actual source state only */
    int32_t muted; /* -1 unknown */
    double volume; /* <0 unknown, else actual source 0...1 */
} PeelViewerState;
typedef void (*PeelViewerControl)(uint32_t window_id, uint64_t session_generation, int32_t command, double value, void *user);
void peel_linux_viewer_register(PeelViewerControl control, void *user); /* before run */
void peel_linux_viewer_visibility(int32_t show_volume, int32_t show_media); /* presentation only; any thread */
void peel_linux_viewer_state(uint64_t session_generation, uint32_t window_id, const PeelViewerState *state, const char *note); /* any thread; copied */
/* SecretService only; unavailable/locked/error is failure, never plaintext fallback.
 * key attributes are stable host ID; returned secret must be freed by helper. */
char *peel_linux_secret_lookup(const char *stable_id);
int peel_linux_secret_store(const char *stable_id, const char *secret);
void peel_linux_secret_free(char *secret);
#ifdef __cplusplus
}
#endif
