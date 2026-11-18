import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import ScreenCaptureKit
import VideoBridge

struct SessionFrame {
    var pixel: CVPixelBuffer?
    var serial: UInt64 = 0
    var receivedAt: TimeInterval = 0
    var reconnectEvidence: ReconnectFrameEvidence?
    var message = "Stopped"
    var reconnects = 0
    var frames: UInt64 = 0
    var width = 0
    var height = 0
    var measuredFPS: Double = 0
}

private final class ScreenCaptureStream: ScreenCaptureLifecycleStream {
    let stream: SCStream

    init(_ stream: SCStream) { self.stream = stream }

    func start(completion: @escaping (Error?) -> Void) {
        stream.startCapture(completionHandler: completion)
    }

    func stop(completion: @escaping (Error?) -> Void) {
        stream.stopCapture(completionHandler: completion)
    }
}

final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // Capture configuration and delegate callbacks are serialized on queue.
    private var capture: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?
    private let screenLifecycle = ScreenCaptureLifecycle()
    private var fpsStarted: TimeInterval = 0
    private var fpsFrames = 0
    private let condition = NSCondition()
    private var decoder: OpaquePointer?
    private var stopped = false
    private var frame = SessionFrame()
    private let queue = DispatchQueue(label: "CameraWall.decoder", qos: .userInitiated)
    let attemptID: UUID

    init(attemptID: UUID = UUID()) {
        self.attemptID = attemptID
        super.init()
    }

    func start(url: String) { queue.async { [self] in run(url: url) } }

    func start(fileURL: URL, accessAlreadyStarted: Bool = false) {
        guard fileURL.isFileURL else {
            if accessAlreadyStarted { fileURL.stopAccessingSecurityScopedResource() }
            setError("Select a local video file.")
            return
        }
        queue.async { [self] in
            defer { if accessAlreadyStarted { fileURL.stopAccessingSecurityScopedResource() } }
            run(url: fileURL.path, filePlayback: true)
        }
    }

    func snapshot() -> SessionFrame {
        condition.lock()
        defer { condition.unlock() }
        return frame
    }

    func stop() {
        condition.lock()
        stopped = true
        if let decoder { cw_stop(decoder) }
        frame = SessionFrame()
        condition.broadcast()
        condition.unlock()
        screenLifecycle.stop()
        queue.async { [self] in
            capture?.stopRunning()
            capture = nil
            captureDevice = nil
        }
    }

    static func localDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    func start(deviceID: String) {
        setError("Requesting camera access")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { [self] in maintainCapture(deviceID: deviceID) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                self?.cameraAccessResolved(allowed: allowed, deviceID: deviceID)
            }
        default:
            setError("Allow CameraWall in System Settings → Privacy & Security → Camera.")
        }
    }

    func cameraAccessResolved(allowed: Bool, deviceID: String) {
        if allowed { queue.async { [self] in maintainCapture(deviceID: deviceID) } }
        else { setError("Allow CameraWall in System Settings → Privacy & Security → Camera.") }
    }

    func startScreen(displayID: String) {
        guard let numericID = UInt32(displayID) else {
            setError("Select a valid display.")
            return
        }
        if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            setError("Allow CameraWall in System Settings → Privacy & Security → Screen & System Audio Recording.")
            return
        }
        queue.async { [self] in
            Task { [weak self] in await self?.startScreenCapture(displayID: numericID) }
        }
    }

    private func startScreenCapture(displayID: UInt32) async {
        await startScreenCapture {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenCaptureError.displayUnavailable
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.queueDepth = 3
            configuration.showsCursor = true
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            return ScreenCaptureStream(stream)
        }
    }

    private enum ScreenCaptureError: Error { case displayUnavailable }

    func startScreenCapture(makeStream: () async throws -> any ScreenCaptureLifecycleStream) async {
        await screenLifecycle.start(makeStream: makeStream) { [weak self] result in
            let message: String
            switch result {
            case .success:
                message = "Live · ScreenCaptureKit"
            case .failure(let error) where error is ScreenCaptureError:
                message = "The selected screen is unavailable."
            case .failure:
                message = "Screen capture could not start. Check Screen Recording permission."
            }
            self?.setScreenMessage(message)
        }
    }

    private func setScreenMessage(_ message: String) {
        condition.lock()
        defer { condition.unlock() }
        if !stopped { frame.message = message }
    }

    private func maintainCapture(deviceID: String) {
        condition.lock()
        let shouldStop = stopped
        condition.unlock()
        guard !shouldStop else { return }
        if capture == nil || captureDevice?.isConnected != true || capture?.isRunning != true {
            capture?.stopRunning()
            capture = nil
            captureDevice = nil
            condition.lock()
            frame.pixel = nil
            frame.reconnectEvidence = nil
            frame.measuredFPS = 0
            condition.unlock()
            if let device = Self.localDevices().first(where: { $0.uniqueID == deviceID }) {
                do {
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        setError("Camera input unavailable. Close other camera apps and retry.")
                        scheduleCaptureRetry(deviceID)
                        return
                    }
                    session.addInput(input)
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        setError("Camera video output unavailable.")
                        scheduleCaptureRetry(deviceID)
                        return
                    }
                    session.addOutput(output)
                    session.commitConfiguration()
                    capture = session
                    captureDevice = device
                    fpsStarted = ProcessInfo.processInfo.systemUptime
                    fpsFrames = 0
                    setError("Connecting to camera")
                    runLocalCaptureStart(start: { session.startRunning() },
                                         stop: { session.stopRunning() })
                } catch {
                    setError("Cannot open camera. Close other camera apps and check camera access.")
                }
            } else {
                setError("Camera unavailable. Connect your camera or enable iPhone Continuity Camera.")
            }
        }
        scheduleCaptureRetry(deviceID)
    }

    private func scheduleCaptureRetry(_ deviceID: String) {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.maintainCapture(deviceID: deviceID)
        }
    }

    // startRunning can finish after stop was requested. Cleanup must happen on
    // the capture queue as soon as it returns, before any queued retry runs.
    func runLocalCaptureStart(start: () -> Void, stop: () -> Void) {
        condition.lock()
        let cancelled = stopped
        condition.unlock()
        guard !cancelled else { return }
        start()
        condition.lock()
        let cancelledDuringStart = stopped
        condition.unlock()
        if cancelledDuringStart { stop() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        publish(pixel, message: "Live · AVFoundation")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        publish(pixel, message: "Live · ScreenCaptureKit")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        setScreenMessage("Screen capture stopped. Check Screen Recording permission.")
    }

    func publish(_ pixel: CVPixelBuffer, message: String) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { return }
        frame.pixel = pixel
        frame.serial &+= 1
        frame.frames &+= 1
        frame.receivedAt = ProcessInfo.processInfo.systemUptime
        frame.reconnectEvidence = ReconnectFrameEvidence(
            attemptID: attemptID, sequence: frame.serial, receivedAt: ContinuousClock().now)
        frame.width = CVPixelBufferGetWidth(pixel)
        frame.height = CVPixelBufferGetHeight(pixel)
        fpsFrames += 1
        let elapsed = frame.receivedAt - fpsStarted
        if elapsed >= 1 {
            frame.measuredFPS = Double(fpsFrames) / elapsed
            fpsFrames = 0
            fpsStarted = frame.receivedAt
        }
        frame.message = message
    }

    private func run(url: String, filePlayback: Bool = false) {
        var failures = 0
        while true {
            condition.lock()
            if stopped { condition.unlock(); return }
            let handle = cw_create()
            decoder = handle
            frame.message = failures == 0 ? "Connecting" : "Reconnecting"
            condition.unlock()
            guard let handle else { setError("Decoder allocation failed"); return }
            var error = filePlayback
                ? cw_open_file(handle, url, 5000)
                : cw_open(handle, url, 5000)
            if error >= 0 {
                var windowStarted = ProcessInfo.processInfo.systemUptime
                var windowFrames: UInt64 = 0
                while let unmanaged = cw_next(handle, &error) {
                    let pixel = unmanaged.takeRetainedValue()
                    condition.lock()
                    if stopped { condition.unlock(); break }
                    frame.pixel = pixel
                    frame.serial &+= 1
                    frame.frames &+= 1
                    frame.receivedAt = ProcessInfo.processInfo.systemUptime
                    frame.reconnectEvidence = ReconnectFrameEvidence(
                        attemptID: attemptID, sequence: frame.serial, receivedAt: ContinuousClock().now)
                    frame.width = CVPixelBufferGetWidth(pixel)
                    frame.height = CVPixelBufferGetHeight(pixel)
                    windowFrames += 1
                    let elapsed = frame.receivedAt - windowStarted
                    if elapsed >= 1 {
                        frame.measuredFPS = Double(windowFrames) / elapsed
                        windowFrames = 0
                        windowStarted = frame.receivedAt
                    }
                    frame.message = "Live · VideoToolbox"
                    condition.unlock()
                    failures = 0
                }
            }
            retireDecoder { cw_destroy(handle) }
            condition.lock()
            if stopped { condition.unlock(); return }
            var buffer = [CChar](repeating: 0, count: 256)
            cw_error(error, &buffer, Int32(buffer.count))
            if filePlayback {
                frame.message = cw_is_eof(error) != 0 ? "End of video" : String(cString: buffer)
                condition.unlock()
                return
            }
            frame.message = String(cString: buffer)
            frame.reconnects += 1
            failures += 1
            let delay = min(15.0, pow(2.0, Double(min(failures - 1, 4))))
                + Double.random(in: 0...0.3)
            let deadline = Date().addingTimeInterval(delay)
            while !stopped && Date() < deadline { _ = condition.wait(until: deadline) }
            let shouldStop = stopped
            condition.unlock()
            if shouldStop { return }
        }
    }

    // Called on the decoder queue after its last read. A concurrent stop may
    // see no handle, but must never wait for decoder destruction.
    func retireDecoder(destroy: () -> Void) {
        condition.lock()
        decoder = nil
        frame.pixel = nil
        frame.reconnectEvidence = nil
        frame.measuredFPS = 0
        condition.unlock()
        destroy()
    }

    private func setError(_ message: String) {
        condition.lock()
        if !stopped { frame.message = message }
        condition.unlock()
    }
}