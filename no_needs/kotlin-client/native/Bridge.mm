#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#include <jni.h>
#include <jawt.h>
#include <jawt_md.h>
#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/app/gstappsink.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <atomic>
#include <mutex>

@interface CWVideoSession : NSObject {
@public
    GstElement *pipeline;
    GstElement *sink;
    std::atomic<uint64_t> frames;
    std::atomic<uint64_t> rendered;
    std::atomic<int64_t> receivedAt;
    std::atomic<int> width;
    std::atomic<int> height;
    std::atomic<int> errorCode;
    std::atomic<bool> linked;
    BOOL testSource;
}
@property(nonatomic, strong) id<JAWT_SurfaceLayers> host;
@property(nonatomic, strong) CALayer *root;
@property(nonatomic, strong) CALayer *video;
@end
@implementation CWVideoSession
@end

struct CWMappedFrame { GstVideoFrame frame; GstSample *sample; };

static void release_pixel(void *opaque, const void *data, size_t size, size_t planes, const void *addresses[]) {
    CWMappedFrame *mapped = static_cast<CWMappedFrame *>(opaque);
    gst_video_frame_unmap(&mapped->frame);
    gst_sample_unref(mapped->sample);
    delete mapped;
}

static GstFlowReturn on_sample(GstAppSink *sink, gpointer opaque) {
    @autoreleasepool {
        CWVideoSession *session = (__bridge CWVideoSession *)opaque;
        GstSample *sample = gst_app_sink_pull_sample(sink);
        if (!sample) return GST_FLOW_EOS;
        AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)session.video;
        if (!layer || !layer.readyForMoreMediaData) { gst_sample_unref(sample); return GST_FLOW_OK; }
        GstVideoInfo info;
        if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) || GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_NV12) {
            gst_sample_unref(sample); session->errorCode.store(-6); return GST_FLOW_NOT_NEGOTIATED;
        }
        CWMappedFrame *mapped = new CWMappedFrame{};
        mapped->sample = sample;
        if (!gst_video_frame_map(&mapped->frame, &info, gst_sample_get_buffer(sample), GST_MAP_READ)) {
            gst_sample_unref(sample); delete mapped; return GST_FLOW_ERROR;
        }
        size_t widths[] = {(size_t)GST_VIDEO_INFO_WIDTH(&info), (size_t)(GST_VIDEO_INFO_WIDTH(&info) + 1) / 2};
        size_t heights[] = {(size_t)GST_VIDEO_INFO_HEIGHT(&info), (size_t)(GST_VIDEO_INFO_HEIGHT(&info) + 1) / 2};
        size_t strides[] = {(size_t)GST_VIDEO_FRAME_PLANE_STRIDE(&mapped->frame, 0), (size_t)GST_VIDEO_FRAME_PLANE_STRIDE(&mapped->frame, 1)};
        CVPixelBufferRef pixel = NULL;
        CVReturn result = CVPixelBufferCreateWithPlanarBytes(NULL, widths[0], heights[0], kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            mapped, info.size, 2, mapped->frame.data, widths, heights, strides, release_pixel, mapped, NULL, &pixel);
        if (result != kCVReturnSuccess) {
            gst_video_frame_unmap(&mapped->frame); gst_sample_unref(sample); delete mapped; return GST_FLOW_ERROR;
        }
        CMVideoFormatDescriptionRef format = NULL;
        CMSampleBufferRef buffer = NULL;
        CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid};
        if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel, &format) == noErr &&
            CMSampleBufferCreateReadyWithImageBuffer(NULL, pixel, format, &timing, &buffer) == noErr) {
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, TRUE);
            if (CFArrayGetCount(attachments)) CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];
            [layer enqueueSampleBuffer:buffer];
            session->rendered.fetch_add(1);
        }
        if (buffer) CFRelease(buffer);
        if (format) CFRelease(format);
        CFRelease(pixel);
        return GST_FLOW_OK;
    }
}

static void main_sync(dispatch_block_t block) {
    if ([NSThread isMainThread]) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}

static void throw_error(JNIEnv *env, const char *message) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message);
}

static CWVideoSession *session_for(jlong handle) { return (__bridge CWVideoSession *)(void *)handle; }

static GstPadProbeReturn on_frame(GstPad *pad, GstPadProbeInfo *info, gpointer opaque) {
    CWVideoSession *session = (__bridge CWVideoSession *)opaque;
    session->frames.fetch_add(1);
    session->receivedAt.store(g_get_monotonic_time());
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (caps) {
        GstVideoInfo videoInfo;
        if (gst_video_info_from_caps(&videoInfo, caps)) {
            session->width.store(GST_VIDEO_INFO_WIDTH(&videoInfo));
            session->height.store(GST_VIDEO_INFO_HEIGHT(&videoInfo));
        }
        gst_caps_unref(caps);
    }
    return GST_PAD_PROBE_OK;
}

static GstBusSyncReply on_bus(GstBus *bus, GstMessage *message, gpointer opaque) {
    CWVideoSession *session = (__bridge CWVideoSession *)opaque;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        GError *error = NULL;
        gchar *debug = NULL;
        gst_message_parse_error(message, &error, &debug);
        session->errorCode.store(error ? error->code : -1);
        g_clear_error(&error);
        g_free(debug);
    } else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) {
        session->errorCode.store(-2);
    }
    gst_message_unref(message);
    return GST_BUS_DROP;
}

static void on_rtp_pad(GstElement *source, GstPad *pad, gpointer opaque) {
    CWVideoSession *session = (__bridge CWVideoSession *)opaque;
    if (session->linked.load()) return;
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) return;
    const GstStructure *structure = gst_caps_get_structure(caps, 0);
    const char *media = gst_structure_get_string(structure, "media");
    const char *encoding = gst_structure_get_string(structure, "encoding-name");
    bool video = media && strcmp(media, "video") == 0;
    bool h264 = encoding && strcmp(encoding, "H264") == 0;
    bool h265 = encoding && (strcmp(encoding, "H265") == 0 || strcmp(encoding, "HEVC") == 0);
    gst_caps_unref(caps);
    if (!video || (!h264 && !h265)) return;
    if (session->linked.exchange(true)) return;
    GstElement *depay = gst_element_factory_make(h264 ? "rtph264depay" : "rtph265depay", NULL);
    GstElement *parser = gst_element_factory_make(h264 ? "h264parse" : "h265parse", NULL);
    GstElement *decoder = gst_element_factory_make("vtdec_hw", NULL);
    GstElement *queue = gst_element_factory_make("queue", NULL);
    if (!depay || !parser || !decoder || !queue) {
        for (GstElement *element : {depay, parser, decoder, queue}) if (element) gst_object_unref(element);
        session->errorCode.store(-3);
        return;
    }
    g_object_set(depay, "request-keyframe", TRUE, "wait-for-keyframe", TRUE, NULL);
    g_object_set(queue, "leaky", 2, "max-size-buffers", 1, "max-size-bytes", 0, "max-size-time", (guint64)0, NULL);
    gst_bin_add_many(GST_BIN(session->pipeline), depay, parser, decoder, queue, NULL);
    if (!gst_element_link_many(depay, parser, decoder, queue, session->sink, NULL)) {
        session->errorCode.store(-4);
        return;
    }
    for (GstElement *element : {depay, parser, decoder, queue}) gst_element_sync_state_with_parent(element);
    GstPad *target = gst_element_get_static_pad(depay, "sink");
    if (gst_pad_link(pad, target) != GST_PAD_LINK_OK) session->errorCode.store(-5);
    gst_object_unref(target);
}

extern "C" JNIEXPORT jlong JNICALL Java_camerawall_NativeVideo_create(JNIEnv *env, jobject owner, jobject canvas, jstring address, jboolean test) {
    static std::once_flag once;
    std::call_once(once, [] { gst_init(NULL, NULL); gst_debug_set_default_threshold(GST_LEVEL_NONE); });
    CWVideoSession *session = [CWVideoSession new];
    session->testSource = test;
    session->pipeline = gst_pipeline_new(NULL);
    session->sink = gst_element_factory_make("appsink", "display");
    if (!session->pipeline || !session->sink) {
        if (session->pipeline) gst_object_unref(session->pipeline);
        throw_error(env, "GStreamer appsink is unavailable."); return 0;
    }
    GstCaps *outputCaps = gst_caps_from_string("video/x-raw,format=NV12");
    g_object_set(session->sink, "sync", FALSE, "async", FALSE, "enable-last-sample", FALSE,
                 "emit-signals", TRUE, "max-buffers", 1, "drop", TRUE, "caps", outputCaps, NULL);
    gst_caps_unref(outputCaps);
    g_signal_connect(session->sink, "new-sample", G_CALLBACK(on_sample), (__bridge void *)session);
    if (canvas) main_sync(^{
        AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer layer];
        layer.videoGravity = AVLayerVideoGravityResizeAspect;
        session.video = layer;
    });
    gst_bin_add(GST_BIN(session->pipeline), session->sink);
    GstPad *sinkPad = gst_element_get_static_pad(session->sink, "sink");
    gst_pad_add_probe(sinkPad, GST_PAD_PROBE_TYPE_BUFFER, on_frame, (__bridge void *)session, NULL);
    gst_object_unref(sinkPad);
    GstBus *bus = gst_element_get_bus(session->pipeline);
    gst_bus_set_sync_handler(bus, on_bus, (__bridge void *)session, NULL);
    gst_object_unref(bus);
    GstElement *source = gst_element_factory_make(test ? "videotestsrc" : "rtspsrc", "source");
    if (!source) { gst_object_unref(session->pipeline); throw_error(env, "GStreamer source plugin unavailable."); return 0; }
    gst_bin_add(GST_BIN(session->pipeline), source);
    if (test) {
        g_object_set(source, "is-live", TRUE, "pattern", 0, NULL);
        GstCaps *caps = gst_caps_from_string("video/x-raw,format=NV12,width=640,height=360,framerate=15/1");
        if (!gst_element_link_filtered(source, session->sink, caps)) session->errorCode.store(-4);
        gst_caps_unref(caps);
    } else {
        const char *url = env->GetStringUTFChars(address, NULL);
        g_object_set(source, "location", url, "protocols", 4, "latency", 50, "drop-on-latency", TRUE,
                     "tcp-timeout", (guint64)5000000, NULL);
        env->ReleaseStringUTFChars(address, url);
        g_signal_connect(source, "pad-added", G_CALLBACK(on_rtp_pad), (__bridge void *)session);
    }
    gst_element_set_state(session->pipeline, GST_STATE_READY);
    if (!canvas) {
        gst_element_set_state(session->pipeline, GST_STATE_PLAYING);
        return (jlong)(__bridge_retained void *)session;
    }
    JAWT awt = {};
    awt.version = JAWT_VERSION_9;
    if (!session.video || !JAWT_GetAWT(env, &awt)) {
        gst_element_set_state(session->pipeline, GST_STATE_NULL); gst_object_unref(session->pipeline);
        throw_error(env, "Native JVM drawing surface is unavailable."); return 0;
    }
    JAWT_DrawingSurface *surface = awt.GetDrawingSurface(env, canvas);
    if (!surface) {
        gst_element_set_state(session->pipeline, GST_STATE_NULL); gst_object_unref(session->pipeline);
        throw_error(env, "Video canvas must be visible before attaching GStreamer."); return 0;
    }
    jint locked = surface->Lock(surface);
    JAWT_DrawingSurfaceInfo *info = (locked & JAWT_LOCK_ERROR) ? NULL : surface->GetDrawingSurfaceInfo(surface);
    if (info) {
        session.host = (__bridge id<JAWT_SurfaceLayers>)info->platformInfo;
        surface->FreeDrawingSurfaceInfo(info);
    }
    if (!(locked & JAWT_LOCK_ERROR)) surface->Unlock(surface);
    awt.FreeDrawingSurface(surface);
    if (!session.host) {
        gst_element_set_state(session->pipeline, GST_STATE_NULL); gst_object_unref(session->pipeline);
        throw_error(env, "Cannot attach video to the JVM canvas."); return 0;
    }
    main_sync(^{
        session.root = [CALayer layer];
        session.root.backgroundColor = NSColor.blackColor.CGColor;
        session.host.layer = session.root;
        session.video.frame = session.root.bounds;
        session.video.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [session.root addSublayer:session.video];
    });
    gst_element_set_state(session->pipeline, GST_STATE_PLAYING);
    return (jlong)(__bridge_retained void *)session;
}

extern "C" JNIEXPORT jlongArray JNICALL Java_camerawall_NativeVideo_metrics(JNIEnv *env, jobject owner, jlong handle) {
    CWVideoSession *session = session_for(handle);
    jlong values[] = {(jlong)session->frames.load(), session->width.load(), session->height.load(),
        session->receivedAt.load() ? (g_get_monotonic_time() - session->receivedAt.load()) / 1000 : -1,
        session->errorCode.load(), (jlong)session->rendered.load()};
    jlongArray result = env->NewLongArray(6);
    env->SetLongArrayRegion(result, 0, 6, values);
    return result;
}

extern "C" JNIEXPORT void JNICALL Java_camerawall_NativeVideo_close(JNIEnv *env, jobject owner, jlong handle) {
    CWVideoSession *session = (__bridge_transfer CWVideoSession *)(void *)handle;
    gst_element_set_state(session->pipeline, GST_STATE_NULL);
    GstBus *bus = gst_element_get_bus(session->pipeline);
    gst_bus_set_sync_handler(bus, NULL, NULL, NULL);
    gst_object_unref(bus);
    gst_object_unref(session->pipeline);
    main_sync(^{ [session.video removeFromSuperlayer]; session.host.layer = nil; });
}

extern "C" JNIEXPORT void JNICALL Java_camerawall_NativeVideo_blank(JNIEnv *env, jobject owner, jlong handle) {
    CWVideoSession *session = session_for(handle);
    main_sync(^{ [(AVSampleBufferDisplayLayer *)session.video flushAndRemoveImage]; });
}

extern "C" JNIEXPORT jint JNICALL Java_camerawall_NativeVideo_writeSecret(JNIEnv *env, jobject owner, jstring account, jstring value) {
    const char *rawAccount = env->GetStringUTFChars(account, NULL);
    const char *rawValue = env->GetStringUTFChars(value, NULL);
    NSString *key = [NSString stringWithUTF8String:rawAccount];
    NSData *data = [[NSString stringWithUTF8String:rawValue] dataUsingEncoding:NSUTF8StringEncoding];
    env->ReleaseStringUTFChars(account, rawAccount);
    env->ReleaseStringUTFChars(value, rawValue);
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"CameraWall.Kotlin.RTSP", (__bridge id)kSecAttrAccount: key};
    OSStatus result = SecItemUpdate((__bridge CFDictionaryRef)query,
                                   (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (result == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy];
        item[(__bridge id)kSecValueData] = data;
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        result = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return result;
}

extern "C" JNIEXPORT jstring JNICALL Java_camerawall_NativeVideo_readSecret(JNIEnv *env, jobject owner, jstring account) {
    const char *rawAccount = env->GetStringUTFChars(account, NULL);
    NSString *key = [NSString stringWithUTF8String:rawAccount];
    env->ReleaseStringUTFChars(account, rawAccount);
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"CameraWall.Kotlin.RTSP", (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecReturnData: @YES};
    CFTypeRef item = NULL;
    OSStatus result = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
    if (result == errSecItemNotFound) return NULL;
    if (result != errSecSuccess) { throw_error(env, "Cannot read camera credentials from Keychain."); return NULL; }
    NSData *data = CFBridgingRelease(item);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return env->NewStringUTF(text.UTF8String ?: "");
}