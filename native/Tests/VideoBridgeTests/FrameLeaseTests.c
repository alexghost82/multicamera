// Standalone synthetic test; no media inputs or devices are opened.
// From the repository root, compile with the VideoBridge and FFmpeg include
// paths, link avformat/avcodec/avutil and CoreVideo/CoreFoundation, then run.
#define avcodec_receive_frame synthetic_receive_frame
#include "../../Sources/VideoBridge/VideoBridge.c"
#undef avcodec_receive_frame
#include <assert.h>
#include <stdio.h>

static CVPixelBufferRef input;
static int releases;
static enum AVPixelFormat output_format = AV_PIX_FMT_VIDEOTOOLBOX;

static void release_frame(void *opaque, uint8_t *data) {
    (void)opaque;
    ++releases;
    CVPixelBufferRelease((CVPixelBufferRef)data);
}

int synthetic_receive_frame(AVCodecContext *codec, AVFrame *frame) {
    (void)codec;
    CVPixelBufferRetain(input);
    frame->buf[0] = av_buffer_create((uint8_t *)input, 1, release_frame, NULL, 0);
    assert(frame->buf[0]);
    frame->data[3] = (uint8_t *)input;
    frame->format = output_format;
    return 0;
}

static CWDecoder *synthetic_decoder(void) {
    CWDecoder *decoder = cw_create();
    assert(decoder);
    decoder->frame = av_frame_alloc();
    assert(decoder->frame);
    decoder->timeout = 1000000;
    return decoder;
}

int main(void) {
    assert(CVPixelBufferCreate(NULL, 4, 4, kCVPixelFormatType_32BGRA, NULL, &input) == kCVReturnSuccess);
    int error = 0;
    CWDecoder *decoder = synthetic_decoder();
    CVPixelBufferRef result = cw_next(decoder, &error);
    assert(result == input && error == 0 && releases == 0);
    cw_stop(decoder);
    assert(cw_next(decoder, &error) == NULL && releases == 1);
    CVPixelBufferRelease(result);
    cw_destroy(decoder);

    decoder = synthetic_decoder();
    result = cw_next(decoder, &error);
    assert(result == input && releases == 1);
    cw_destroy(decoder);
    assert(releases == 2);
    CVPixelBufferRelease(result);

    decoder = synthetic_decoder();
    output_format = AV_PIX_FMT_NONE;
    assert(cw_next(decoder, &error) == NULL && releases == 3);
    cw_destroy(decoder);
    CVPixelBufferRelease(input);
    puts("Synthetic frame lease tests passed");
    return 0;
}
