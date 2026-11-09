import AppKit
import AVFoundation
import SwiftUI

final class VideoSurface: NSView {
    let display = AVSampleBufferDisplayLayer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var receiver: AVSampleBufferVideoRenderer.Receiver?
    private var serial: UInt64 = 0
    private var isFlushing = false
    private var pendingFrame: SessionFrame?

    override init(frame: NSRect) {
        super.init(frame: frame)
        receiver = synchronizer.sampleBufferReceiver(adding: display.sampleBufferRenderer)
        synchronizer.rate = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
        setAccessibilityLabel("Camera video")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        CATransaction.commit()
    }

    func present(_ frame: SessionFrame, stale: Bool) {
        guard !stale, let pixel = frame.pixel else {
            pendingFrame = nil
            if serial != 0 { flushRenderer(removingDisplayedImage: true) }
            return
        }
        guard serial != frame.serial else { return }
        guard !isFlushing else { pendingFrame = frame; return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        guard let receiver else { return }
        let readySample = CMReadySampleBuffer(unsafeBuffer: sample)
        switch receiver.enqueueImmediately(readySample) {
        case .enqueued, .enqueuedWithDecodeFailures(_):
            serial = frame.serial
        case .cancelledDueToFlush:
            pendingFrame = frame
        case .cancelledDueToFlushRequiredToResume(_):
            pendingFrame = frame
            flushRenderer(removingDisplayedImage: false)
        case .cancelledDueToError(_):
            pendingFrame = frame
        @unknown default:
            pendingFrame = frame
        }
    }

    private func flushRenderer(removingDisplayedImage: Bool) {
        guard !isFlushing, let receiver else { return }
        isFlushing = true
        Task { [weak self] in
            await receiver.flush(removingDisplayedImage: removingDisplayedImage)
            guard let self else { return }
            self.serial = 0
            self.isFlushing = false
            guard let pendingFrame = self.pendingFrame else { return }
            self.pendingFrame = nil
            self.present(pendingFrame, stale: false)
        }
    }
}

struct VideoView: NSViewRepresentable {
    var frame: SessionFrame
    var stale: Bool
    func makeNSView(context: Context) -> VideoSurface { VideoSurface(frame: .zero) }
    func updateNSView(_ view: VideoSurface, context: Context) { view.present(frame, stale: stale) }
}