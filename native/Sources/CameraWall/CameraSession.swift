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

final class CameraSessionDrainTracker: @unchecked Sendable {
    static let shared = CameraSessionDrainTracker()
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Error>] = [:]
    private var failed = false

    func stop(_ session: CameraSession) {
        session.stop()
        track(session)
    }

    fileprivate func track(_ session: CameraSession) {
        let id = UUID()
        lock.lock()
        let task = Task { try await session.waitAfterStop() }
        tasks[id] = task
        lock.unlock()
        Task {
            let result = await task.result
            finish(id, result: result)
        }
    }

    func wait() async throws {
        while true {
            let (current, failure) = snapshot()
            if current.isEmpty {
                if failure { throw DrainFailure() }
                return
            }
            for (id, task) in current {
                let result = await task.result
                finish(id, result: result)
            }
        }
    }

    private func snapshot() -> ([UUID: Task<Void, Error>], Bool) {
        lock.lock(); defer { lock.unlock() }
        return (tasks, failed)
    }

    private func finish(_ id: UUID, result: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard tasks.removeValue(forKey: id) != nil else { return }
        if case .failure = result { failed = true }
    }

    private struct DrainFailure: Error {}
}

final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // Capture configuration and sample callbacks use queue; stream errors may not.
    private var capture: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?
    private let screenLifecycle = ScreenCaptureLifecycle()
    private var fpsStarted: TimeInterval = 0
    private var fpsFrames = 0
    private let condition = NSCondition()
    private let frameCapture: ACTAFrameCaptureGate
    private let startupWork = CameraRuntimeWorkGroup()
    private let retryWork = CameraRuntimeWorkGroup()
    private let delegateWork = CameraRuntimeWorkGroup()
    private var decoder: OpaquePointer?
    private var stopped = false
    private var frame = SessionFrame()
    private let queue = DispatchQueue(label: "CameraWall.decoder", qos: .userInitiated)
    private var captureRetryTimers: [UUID: any DispatchSourceTimer] = [:]
    let attemptID: UUID

    init(attemptID: UUID = UUID(), frameCapture: ACTAFrameCaptureGate = ACTAFrameCaptureGate()) {
        self.attemptID = attemptID
        self.frameCapture = frameCapture
        super.init()
    }

    deinit {
        for timer in captureRetryTimers.values { timer.cancel() }
    }

    func start(url: String) {
        guard let ticket = startupWork.begin() else { return }
        queue.async { [self] in
            defer { ticket.finish() }
            run(url: url)
        }
    }

    func start(fileURL: URL, accessAlreadyStarted: Bool = false) {
        guard fileURL.isFileURL else {
            if accessAlreadyStarted { fileURL.stopAccessingSecurityScopedResource() }
            setError("Select a local video file.")
            return
        }
        guard let ticket = startupWork.begin() else {
            if accessAlreadyStarted { fileURL.stopAccessingSecurityScopedResource() }
            return
        }
        queue.async { [self] in
            defer { ticket.finish() }
            defer { if accessAlreadyStarted { fileURL.stopAccessingSecurityScopedResource() } }
            run(url: fileURL.path, filePlayback: true)
        }
    }

    func snapshot() -> SessionFrame {
        condition.lock()
        defer { condition.unlock() }
        return frame
    }

    /// Copies the next delivered frame while the producing callback or decoder
    /// still owns it. This does not mutate or retain the producer's storage.
    func captureNextOwnedFrame(timeout: Duration = .seconds(3)) async throws -> ACTAOwnedCameraFrame {
        try await frameCapture.capture(timeout: timeout)
    }

    var hasPendingOwnedFrameCapture: Bool { frameCapture.isAwaitingFrame }

    var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    func stop() {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        stopped = true
        startupWork.fence()
        retryWork.fence()
        delegateWork.fence()
        frameCapture.stop()
        if let decoder { cw_stop(decoder) }
        frame = SessionFrame()
        condition.broadcast()
        screenLifecycle.stop()
        queue.async { [self] in
            for timer in captureRetryTimers.values { timer.cancel() }
            captureRetryTimers.removeAll()
            capture?.stopRunning()
            capture = nil
            captureDevice = nil
        }
        CameraSessionDrainTracker.shared.track(self)
        condition.unlock()
    }

    /// The caller must fence new starts before awaiting this method.
    func stopAndWait() async throws {
        stop()
        try await waitAfterStop()
    }

    fileprivate func waitAfterStop() async throws {
        await startupWork.wait()
        var screenFailure: Error?
        do { try await screenLifecycle.stopAndWait() }
        catch { screenFailure = error }
        await retryWork.wait()
        await delegateWork.wait()
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        if let screenFailure { throw screenFailure }
    }

    /// Call after all new session starts and stops have been fenced and joined.
    static func waitForStoppedSessions() async throws {
        try await CameraSessionDrainTracker.shared.wait()
    }

    static func localDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    func start(deviceID: String,
               authorizationStatus: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
               requestAccess: (@escaping @Sendable (Bool) -> Void) -> Void = {
                   AVCaptureDevice.requestAccess(for: .video, completionHandler: $0)
               }) {
        guard let ticket = startupWork.begin() else { return }
        setError("Requesting camera access")
        switch authorizationStatus() {
        case .authorized:
            cameraAccessResolved(allowed: true, deviceID: deviceID)
            ticket.finish()
        case .notDetermined:
            requestAccess { [weak self] allowed in
                defer { ticket.finish() }
                self?.cameraAccessResolved(allowed: allowed, deviceID: deviceID)
            }
        default:
            setError("Allow CameraWall in System Settings → Privacy & Security → Camera.")
            ticket.finish()
        }
    }

    func cameraAccessResolved(allowed: Bool, deviceID: String) {
        if allowed { queue.async { [self] in maintainCapture(deviceID: deviceID) } }
        else { setError("Allow CameraWall in System Settings → Privacy & Security → Camera.") }
    }

    func startScreen(displayID: String) {
        guard let ticket = startupWork.begin() else { return }
        guard let numericID = UInt32(displayID) else {
            setError("Select a valid display.")
            ticket.finish()
            return
        }
        if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            setError("Allow CameraWall in System Settings → Privacy & Security → Screen & System Audio Recording.")
            ticket.finish()
            return
        }
        enqueueScreenStart(ticket) { [weak self] in
            await self?.startScreenCapture(displayID: numericID)
        }
    }

    func enqueueScreenStart(_ operation: @escaping @Sendable () async -> Void) {
        guard let ticket = startupWork.begin() else { return }
        enqueueScreenStart(ticket, operation: operation)
    }

    private func enqueueScreenStart(_ ticket: CameraRuntimeWorkGroup.Ticket,
                                    operation: @escaping @Sendable () async -> Void) {
        queue.async {
            Task {
                defer { ticket.finish() }
                await operation()
            }
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
        scheduleCaptureRetry(after: .seconds(2)) { [weak self] in
            self?.maintainCapture(deviceID: deviceID)
        }
    }

    func scheduleCaptureRetry(after delay: DispatchTimeInterval, operation: @escaping @Sendable () -> Void) {
        guard let ticket = retryWork.begin() else { return }
        queue.async { [self] in
            guard !isStopped else { ticket.finish(); return }
            let id = UUID()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setCancelHandler { ticket.finish() }
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.captureRetryTimers.removeValue(forKey: id)?.cancel()
                guard !self.isStopped else { return }
                operation()
            }
            captureRetryTimers[id] = timer
            timer.schedule(deadline: .now() + delay)
            timer.resume()
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
        guard let ticket = delegateWork.begin() else { return }
        defer { ticket.finish() }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        publish(pixel, message: "Live · AVFoundation")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard let ticket = delegateWork.begin() else { return }
        defer { ticket.finish() }
        guard outputType == .screen, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        publish(pixel, message: "Live · ScreenCaptureKit")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let ticket = delegateWork.begin() else { return }
        defer { ticket.finish() }
        setScreenMessage("Screen capture stopped. Check Screen Recording permission.")
    }

    func publish(_ pixel: CVPixelBuffer, message: String) {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
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
        let serial = frame.serial
        let receivedAt = frame.receivedAt
        condition.unlock()
        frameCapture.offer(pixel, serial: serial, receivedAt: receivedAt)
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
                    let serial = frame.serial
                    let receivedAt = frame.receivedAt
                    condition.unlock()
                    frameCapture.offer(pixel, serial: serial, receivedAt: receivedAt)
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