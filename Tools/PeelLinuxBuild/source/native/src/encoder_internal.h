#pragma once
#include <gst/gst.h>
#include <stdint.h>
/* Open/close on GTK main; sample on the capture streaming thread. Every sample
 * carries the immutable portal epoch that created its appsink. */
void peel_encoder_capture_open(uint64_t generation, uint32_t source_kind);
void peel_encoder_capture_sample(uint64_t generation, GstSample *sample);
void peel_encoder_capture_close(uint64_t generation);
