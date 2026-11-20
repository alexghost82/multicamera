#include "VideoBridge.h"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mathematics.h>
#include <libavutil/time.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

struct CWDecoder {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    atomic_bool stopped;
    int64_t deadline;
    int64_t timeout;
    int64_t first_file_pts;
    int64_t file_start_time;
    int stream;
    bool awaiting_keyframe;
    bool pace_file;
};

static int interrupted(void *opaque) {
    CWDecoder *decoder = opaque;
    return atomic_load(&decoder->stopped) || av_gettime_relative() > decoder->deadline;
}

static enum AVPixelFormat hardware_format(AVCodecContext *context, const enum AVPixelFormat *formats) {
    (void)context;
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
    }
    return AV_PIX_FMT_NONE;
}

CWDecoder *cw_create(void) {
    CWDecoder *decoder = calloc(1, sizeof(*decoder));
    if (decoder) atomic_init(&decoder->stopped, false);
    av_log_set_level(AV_LOG_QUIET);
    return decoder;
}

static int cw_open_internal(CWDecoder *decoder, const char *url, int timeout_ms, bool pace_file) {
    if (!decoder) return AVERROR(ENOMEM);
    decoder->timeout = (int64_t)timeout_ms * 1000;
    decoder->deadline = av_gettime_relative() + decoder->timeout;
    decoder->pace_file = pace_file;
    decoder->first_file_pts = AV_NOPTS_VALUE;
    decoder->format = avformat_alloc_context();
    if (!decoder->format) return AVERROR(ENOMEM);
    decoder->format->interrupt_callback = (AVIOInterruptCB){interrupted, decoder};
    decoder->format->flags |= AVFMT_FLAG_NOBUFFER;
    decoder->format->max_delay = 0;
    AVDictionary *options = NULL;
    if (!pace_file) {
        av_dict_set(&options, "rtsp_transport", "tcp", 0);
        av_dict_set(&options, "reorder_queue_size", "0", 0);
    }
    av_dict_set(&options, "probesize", "32768", 0);
    av_dict_set(&options, "analyzeduration", "0", 0);
    int result = avformat_open_input(&decoder->format, url, NULL, &options);
    av_dict_free(&options);
    if (result < 0) return result;
    decoder->stream = av_find_best_stream(decoder->format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (decoder->stream < 0) return decoder->stream;
    const AVCodecParameters *parameters = decoder->format->streams[decoder->stream]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    bool hardware = false;
    for (int index = 0; ; ++index) {
        const AVCodecHWConfig *config = avcodec_get_hw_config(codec, index);
        if (!config) break;
        if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
            (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) hardware = true;
    }
    if (!hardware) return AVERROR(ENOTSUP);
    decoder->codec = avcodec_alloc_context3(codec);
    if (!decoder->codec) return AVERROR(ENOMEM);
    result = avcodec_parameters_to_context(decoder->codec, parameters);
    if (result < 0) return result;
    decoder->codec->get_format = hardware_format;
    decoder->codec->thread_count = 1;
    decoder->codec->flags |= AV_CODEC_FLAG_LOW_DELAY;
    result = av_hwdevice_ctx_create(&decoder->codec->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
    if (result < 0) return result;
    result = avcodec_open2(decoder->codec, codec, NULL);
    if (result < 0) return result;
    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    decoder->awaiting_keyframe = true;
    return decoder->packet && decoder->frame ? 0 : AVERROR(ENOMEM);
}

int cw_open(CWDecoder *decoder, const char *url, int timeout_ms) {
    return cw_open_internal(decoder, url, timeout_ms, false);
}

int cw_open_file(CWDecoder *decoder, const char *path, int timeout_ms) {
    return cw_open_internal(decoder, path, timeout_ms, true);
}

int cw_is_eof(int error) { return error == AVERROR_EOF; }

CVPixelBufferRef cw_next(CWDecoder *decoder, int *error) {
    // Keep the previous AVFrame lease until the caller has finished processing
    // it and asks for the next frame. A CVPixelBuffer retain is not an
    // AVBufferPool lease.
    av_frame_unref(decoder->frame);
    decoder->deadline = av_gettime_relative() + decoder->timeout;
    while (!interrupted(decoder)) {
        int result = avcodec_receive_frame(decoder->codec, decoder->frame);
        if (result == 0) {
            CVPixelBufferRef pixel = NULL;
            if (decoder->frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                pixel = (CVPixelBufferRef)decoder->frame->data[3];
                if (pixel) CVPixelBufferRetain(pixel);
            }
            if (!pixel) av_frame_unref(decoder->frame);
            *error = pixel ? 0 : AVERROR(ENOTSUP);
            return pixel;
        }
        if (result != AVERROR(EAGAIN)) { *error = result; return NULL; }
        result = av_read_frame(decoder->format, decoder->packet);
        if (result < 0) { *error = result; return NULL; }
        if (decoder->packet->stream_index == decoder->stream) {
            if (!decoder->awaiting_keyframe || (decoder->packet->flags & AV_PKT_FLAG_KEY)) {
                if (decoder->pace_file) {
                    int64_t pts = decoder->packet->pts != AV_NOPTS_VALUE
                        ? decoder->packet->pts : decoder->packet->dts;
                    if (pts != AV_NOPTS_VALUE) {
                        if (decoder->first_file_pts == AV_NOPTS_VALUE) {
                            decoder->first_file_pts = pts;
                            decoder->file_start_time = av_gettime_relative();
                        }
                        AVRational time_base = decoder->format->streams[decoder->stream]->time_base;
                        int64_t relative_us = av_rescale_q(
                            pts - decoder->first_file_pts, time_base,
                            (AVRational){1, AV_TIME_BASE}
                        );
                        int64_t target_time = decoder->file_start_time + (relative_us > 0 ? relative_us : 0);
                        int64_t remaining = target_time - av_gettime_relative();
                        while (remaining > 0 && !interrupted(decoder)) {
                            av_usleep((unsigned)(remaining < 10000 ? remaining : 10000));
                            remaining = target_time - av_gettime_relative();
                        }
                    }
                }
                decoder->awaiting_keyframe = false;
                result = avcodec_send_packet(decoder->codec, decoder->packet);
            }
        }
        av_packet_unref(decoder->packet);
        if (result < 0) { *error = result; return NULL; }
    }
    *error = AVERROR_EXIT;
    return NULL;
}

void cw_stop(CWDecoder *decoder) {
    if (decoder) atomic_store(&decoder->stopped, true);
}

void cw_destroy(CWDecoder *decoder) {
    if (!decoder) return;
    av_frame_free(&decoder->frame);
    av_packet_free(&decoder->packet);
    avcodec_free_context(&decoder->codec);
    avformat_close_input(&decoder->format);
    free(decoder);
}

void cw_error(int error, char *buffer, int size) { av_strerror(error, buffer, size); }