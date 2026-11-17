@preconcurrency import AVFoundation
import Foundation
import ImageIO
import OSLog

nonisolated enum CameraFormat: String, CaseIterable, Identifiable, Sendable {
    case proRAW, bayerRAW
    var id: Self { self }
    var title: String {
        self == .proRAW
            ? "Apple ProRAW"
            : String(localized: "camera.format_bayer_raw", defaultValue: "Bayer RAW")
    }
}

nonisolated enum CameraFailure: LocalizedError {
    case unavailable, denied, configuration, rawUnavailable, notReady, noData
    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "camera.error.needs_device",
                defaultValue: "Camera capture needs a physical device.")
        case .denied:
            String(
                localized: "camera.access_denied",
                defaultValue: "Allow camera access in Settings to take photos.")
        case .configuration:
            String(
                localized: "camera.error.start_failed",
                defaultValue: "The camera could not start.")
        case .rawUnavailable:
            String(
                localized: "camera.error.raw_unsupported",
                defaultValue: "This camera does not support RAW capture.")
        case .notReady:
            String(
                localized: "camera.error.not_ready",
                defaultValue: "The camera is not ready. Try again.")
        case .noData:
            String(
                localized: "camera.error.no_raw_data",
                defaultValue: "The camera did not return a RAW photo.")
        }
    }
}

/// Session configuration, capture and file writing run away from the main actor.
actor CameraService {
    nonisolated enum Event: Sendable {
        case ready(Bool)
        case interrupted(String)
        case resumed
        case failed(String)
        case readings(CameraReadings)
    }
    nonisolated let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let video = AVCaptureVideoDataOutput()
    private let meterQueue = DispatchQueue(label: "SpektraCam.CameraMeter", qos: .utility)
    private var meter: CameraMeter?
    private var devices: [String: AVCaptureDevice] = [:]
    private var inputs: [String: AVCaptureDeviceInput] = [:]
    private var lenses: [CameraLens] = []
    private var activeLens: CameraLens?
    private var macro = false
    private var highResolution = false
    private var source: CameraPreviewSource?
    private var formats: [CameraFormat: OSType] = [:]
    private var capture: RAWPhotoCapture?
    private var stopRequested = false
    private var closed = false
    private var observations: [NSObjectProtocol] = []
    private var readiness: NSKeyValueObservation?
    private let controls = CameraControlsDelegate()

    init() {
        let channel = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(8))
        events = channel.stream
        sink = channel.continuation
    }
    struct Configuration: Sendable {
        let source: CameraPreviewSource
        let formats: [CameraFormat]
        let lenses: [CameraLens]
        let selectedLens: CameraLens
        let macro: Bool
        let highResolution: Bool
        let maximumMegapixels: Int
        let exposureBias: Double
        let exposureRange: ClosedRange<Double>
        let flashAvailable: Bool
    }
    func start() async throws -> Configuration {
        guard !closed else { throw CancellationError() }
        #if targetEnvironment(simulator)
            throw CameraFailure.unavailable
        #else
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var allowed = status == .authorized
            if status == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .video)
            }
            guard !closed else { throw CancellationError() }
            guard allowed else { throw CameraFailure.denied }
            if source == nil { try configure() }
            stopRequested = false
            if !session.isRunning { session.startRunning() }
            guard session.isRunning, source != nil else { throw CameraFailure.configuration }
            sink.yield(.ready(output.captureReadiness == .ready))
            return try configuration()
        #endif
    }
    private func configuration() throws -> Configuration {
        guard let source, let activeLens, let device = devices[activeLens.id] else {
            throw CameraFailure.configuration
        }
        return Configuration(
            source: source, formats: CameraFormat.allCases.filter { formats[$0] != nil },
            lenses: lenses, selectedLens: activeLens, macro: macro, highResolution: highResolution,
            maximumMegapixels: Int(
                (Double(maximumDimensions().width) * Double(maximumDimensions().height) / 1_000_000)
                    .rounded()
            ), exposureBias: Double(device.exposureTargetBias),
            exposureRange: max(
                -3, Double(device.minExposureTargetBias))...min(
                    3, Double(device.maxExposureTargetBias)),
            flashAvailable: device.hasFlash && output.supportedFlashModes.contains(.on))
    }
    private func configure() throws {
        // Keep rear sensors explicit for Bayer RAW. The system front-camera proxy follows
        // folding automatically on Duo; its reported common capabilities are authoritative.
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
            ],
            mediaType: .video, position: .unspecified
        ).devices.filter { !$0.isVirtualDevice || $0.position == .front }
        devices = Dictionary(uniqueKeysWithValues: discovered.map { ($0.uniqueID, $0) })
        let candidates = discovered.map {
            CameraLens(
                id: $0.uniqueID, millimeters: Int($0.nominalFocalLengthIn35mmFilm.rounded()),
                front: $0.position == .front,
                macro: $0.deviceType == .builtInUltraWideCamera
                    && $0.isFocusModeSupported(.continuousAutoFocus),
                primary: $0.deviceType == .builtInWideAngleCamera)
        }.sorted { $0.front == $1.front ? $0.millimeters < $1.millimeters : !$0.front }
        guard
            let device = discovered.first(where: {
                $0.position == .back && $0.deviceType == .builtInWideAngleCamera
            }) ?? discovered.first
        else { throw CameraFailure.unavailable }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for old in session.inputs { session.removeInput(old) }
        for old in session.outputs { session.removeOutput(old) }
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: device)
        inputs[device.uniqueID] = input
        guard session.canAddInput(input) else { throw CameraFailure.configuration }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CameraFailure.configuration }
        session.addOutput(output)
        // RAW is an output capability of an attached input, not a property of a model name.
        // Probe once, before starting the session, so unsupported sensors never become controls.
        lenses = []
        for candidate in candidates {
            guard let device = devices[candidate.id] else { continue }
            let candidateInput: AVCaptureDeviceInput
            do { candidateInput = try inputs[candidate.id] ?? AVCaptureDeviceInput(device: device) }
            catch { continue }
            for attached in session.inputs { session.removeInput(attached) }
            guard session.canAddInput(candidateInput) else { continue }
            session.addInput(candidateInput)
            if !rawPixelFormats().isEmpty {
                inputs[candidate.id] = candidateInput
                lenses.append(candidate)
            }
        }
        guard let selected = lenses.first(where: { !$0.front && $0.primary })
            ?? lenses.first(where: { !$0.front }) ?? lenses.first,
            let selectedDevice = devices[selected.id], let selectedInput = inputs[selected.id]
        else { throw CameraFailure.rawUnavailable }
        for attached in session.inputs { session.removeInput(attached) }
        guard session.canAddInput(selectedInput) else { throw CameraFailure.configuration }
        session.addInput(selectedInput)
        if session.canAddOutput(video) {
            session.addOutput(video)
            video.alwaysDiscardsLateVideoFrames = true
            video.automaticallyConfiguresOutputBufferDimensions = false
            video.deliversPreviewSizedOutputBuffers = true
        }
        try configureOutput(device: selectedDevice, macro: false)
        activeLens = selected
        observeSession()
    }
    private func configureOutput(device: AVCaptureDevice, macro: Bool) throws {
        try device.lockForConfiguration()
        device.videoZoomFactor = 1
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = macro ? .near : .none
        }
        device.unlockForConfiguration()
        formats = rawPixelFormats()
        guard !formats.isEmpty else { throw CameraFailure.rawUnavailable }
        output.maxPhotoQualityPrioritization = .quality
        // Shorten the time from press to capture and between captures where the format allows.
        if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = true }
        if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
        if output.isFastCapturePrioritizationSupported {
            output.isFastCapturePrioritizationEnabled = true
        }
        configureControls(device: device)
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        })
        if let selected = highResolution ? dimensions.last : dimensions.first,
            output.maxPhotoDimensions.width != selected.width
                || output.maxPhotoDimensions.height != selected.height
        {
            output.maxPhotoDimensions = selected
        }
        if session.outputs.contains(video) {
            guard
                let type = [
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ].first(where: { video.availableVideoPixelFormatTypes.contains($0) })
            else {
                video.setSampleBufferDelegate(nil, queue: nil)
                meter = nil
                source = CameraPreviewSource(session: session, device: device)
                return
            }
            if (video.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType) != type
            {
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: type]
            }
            let sink = sink
            meter = CameraMeter(device: device) { sink.yield(.readings($0)) }
            video.setSampleBufferDelegate(meter, queue: meterQueue)
        }
        source = CameraPreviewSource(session: session, device: device)
        prepareCapture()
        Log.camera.debug(
            "Photo size: \(self.output.maxPhotoDimensions.width)×\(self.output.maxPhotoDimensions.height)")
    }
    /// Query only after attaching a video input and the photo output to the session.
    private func rawPixelFormats() -> [CameraFormat: OSType] {
        let supportsProRAW = output.isAppleProRAWSupported
        if output.isAppleProRAWEnabled != supportsProRAW {
            output.isAppleProRAWEnabled = supportsProRAW
        }
        var result: [CameraFormat: OSType] = [:]
        for value in output.availableRawPhotoPixelFormatTypes {
            if AVCapturePhotoOutput.isAppleProRAWPixelFormat(value) { result[.proRAW] = value }
            if AVCapturePhotoOutput.isBayerRAWPixelFormat(value) { result[.bayerRAW] = value }
        }
        return result
    }
    /// Camera Control: a light press and slide adjusts exposure for the active lens.
    private func configureControls(device: AVCaptureDevice) {
        guard session.supportsControls else { return }
        for control in session.controls { session.removeControl(control) }
        let exposure = AVCaptureSystemExposureBiasSlider(device: device)
        if session.canAddControl(exposure) { session.addControl(exposure) }
        session.setControlsDelegate(controls, queue: meterQueue)
    }
    private func maximumDimensions() -> CMVideoDimensions {
        (session.inputs.first as? AVCaptureDeviceInput)?.device.activeFormat
            .supportedMaxPhotoDimensions.max {
                Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
            } ?? output.maxPhotoDimensions
    }
    private func photoSettings(format: CameraFormat, flash: Bool = false) throws -> AVCapturePhotoSettings {
        guard let pixelFormat = formats[format] else { throw CameraFailure.rawUnavailable }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: pixelFormat)
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        settings.photoQualityPrioritization =
            format == .bayerRAW ? .speed : (highResolution ? .quality : .balanced)
        if flash, output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        if let codec = settings.availableRawEmbeddedThumbnailPhotoCodecTypes.first {
            let size = output.maxPhotoDimensions
            let scale = min(1, 1080.0 / Double(max(size.width, size.height)))
            settings.rawEmbeddedThumbnailPhotoFormat = [
                AVVideoCodecKey: codec, AVVideoWidthKey: max(1, Int(Double(size.width) * scale)),
                AVVideoHeightKey: max(1, Int(Double(size.height) * scale)),
            ]
        }
        return settings
    }
    private func prepareCapture() {
        let settings = CameraFormat.allCases.compactMap { try? photoSettings(format: $0) }
        output.setPreparedPhotoSettingsArray(settings, completionHandler: nil)
    }
    func setHighResolution(_ enabled: Bool) throws -> Configuration {
        guard capture == nil, let device = (session.inputs.first as? AVCaptureDeviceInput)?.device
        else {
            throw CameraFailure.notReady
        }
        highResolution = enabled
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try configureOutput(device: device, macro: macro)
        return try configuration()
    }
    func selectLens(_ id: String, macro: Bool = false) throws -> Configuration {
        guard !closed, capture == nil, let device = devices[id],
            let lens = lenses.first(where: { $0.id == id }),
            let previous = session.inputs.first as? AVCaptureDeviceInput
        else { throw CameraFailure.notReady }
        let started = ProcessInfo.processInfo.systemUptime
        // Macro on the current ultra-wide lens changes only its focus range.
        if previous.device.uniqueID == id {
            try device.lockForConfiguration()
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = macro && lens.macro ? .near : .none
            }
            device.unlockForConfiguration()
            self.macro = macro && lens.macro
            return try configuration()
        }
        let input = try inputs[id] ?? AVCaptureDeviceInput(device: device)
        inputs[id] = input
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            Log.camera.debug(
                "Lens \(lens.millimeters): \(ProcessInfo.processInfo.systemUptime - started) s")
        }
        session.removeInput(previous)
        do {
            guard session.canAddInput(input) else { throw CameraFailure.configuration }
            session.addInput(input)
            try configureOutput(device: device, macro: macro && lens.macro)
            activeLens = lens
            self.macro = macro && lens.macro
        } catch {
            if session.inputs.contains(input) { session.removeInput(input) }
            if session.canAddInput(previous) { session.addInput(previous) }
            try? configureOutput(device: previous.device, macro: self.macro)
            throw error
        }
        return try configuration()
    }
    func focus(at point: CGPoint) throws {
        guard session.isRunning, !session.isInterrupted, capture == nil,
            let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
            point.x.isFinite, point.y.isFinite
        else { throw CameraFailure.notReady }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let point = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }
    func setExposureBias(_ value: Double) throws {
        guard !closed, session.isRunning, value.isFinite, capture == nil,
            let device = (session.inputs.first as? AVCaptureDeviceInput)?.device
        else { throw CameraFailure.notReady }
        let bias = min(
            max(Float(value), device.minExposureTargetBias), device.maxExposureTargetBias)
        guard abs(bias - device.exposureTargetBias) >= 0.01 else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureTargetBias(bias, completionHandler: nil)
    }
    private func observeSession() {
        guard observations.isEmpty else { return }
        let sink = sink
        let center = NotificationCenter.default
        observations = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
            ) { note in
                let code =
                    (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
                    ?? 0
                Log.camera.info("Interrupted: \(code)")
                let message: String
                switch AVCaptureSession.InterruptionReason(rawValue: code) {
                case .videoDeviceInUseByAnotherClient:
                    message = String(
                        localized: "camera.interrupted.in_use",
                        defaultValue: "Another app is using the camera.")
                case .videoDeviceNotAvailableWithMultipleForegroundApps:
                    message =
                        String(
                            localized: "camera.interrupted.multitasking",
                            defaultValue:
                                "iOS paused camera access while another view is active. Stop screen sharing to resume."
                        )
                case .videoDeviceNotAvailableDueToSystemPressure:
                    message = String(
                        localized: "camera.interrupted.system_pressure",
                        defaultValue: "iOS paused the camera to reduce system load.")
                default:
                    message = String(
                        localized: "camera.interrupted.generic",
                        defaultValue: "The camera will resume when it is available.")
                }
                sink.yield(.interrupted(message))
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
            ) { _ in
                sink.yield(.resumed)
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                sink.yield(
                    .failed(
                        error?.localizedDescription
                            ?? String(
                                localized: "camera.error.stopped",
                                defaultValue: "The camera stopped. Try again.")))
            },
        ]
        readiness = output.observe(\.captureReadiness, options: [.initial, .new]) { output, _ in
            sink.yield(.ready(output.captureReadiness == .ready))
        }
    }
    func stop() {
        stopRequested = true
        if capture == nil && session.isRunning { session.stopRunning() }
    }
    func shutdown() {
        closed = true
        stop()
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        readiness = nil
        video.setSampleBufferDelegate(nil, queue: nil)
        meter = nil
        sink.finish()
    }
    func takePhoto(
        format: CameraFormat, rotation: CGFloat, inbox: CameraInbox, location: CaptureLocation?,
        flash: Bool = false
    )
        async throws -> URL
    {
        guard capture == nil, session.isRunning, !session.isInterrupted,
            output.captureReadiness == .ready
        else { throw CameraFailure.notReady }
        let settings = try photoSettings(format: format, flash: flash)
        guard let connection = output.connection(with: .video) else { throw CameraFailure.notReady }
        let angle =
            connection.isVideoRotationAngleSupported(rotation)
            ? rotation : (rotation / 90).rounded() * 90
        guard connection.isVideoRotationAngleSupported(angle) else {
            throw CameraFailure.configuration
        }
        connection.videoRotationAngle = angle
        defer {
            capture = nil
            if stopRequested && session.isRunning { session.stopRunning() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = RAWPhotoCapture(
                inbox: inbox, location: location, continuation: continuation)
            capture = delegate
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

/// The system needs a delegate before it shows Camera Control overlays; nothing to do here.
nonisolated private final class CameraControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}

/// AVFoundation serializes the callbacks for this single capture request.
nonisolated private final class RAWPhotoCapture: NSObject, AVCapturePhotoCaptureDelegate,
    AVCapturePhotoFileDataRepresentationCustomizer
{
    private let inbox: CameraInbox
    private let continuation: CheckedContinuation<URL, Error>
    private var result: Result<URL, Error>?
    private let location: CaptureLocation?
    private let started = ProcessInfo.processInfo.systemUptime
    init(
        inbox: CameraInbox, location: CaptureLocation?,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.inbox = inbox
        self.location = location
        self.continuation = continuation
    }
    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        if let location { metadata[kCGImagePropertyGPSDictionary as String] = location.gps }
        return metadata
    }
    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            result = .failure(error)
            return
        }
        guard photo.isRawPhoto,
            let data = location == nil
                ? photo.fileDataRepresentation() : photo.fileDataRepresentation(with: self)
        else {
            result = .failure(CameraFailure.noData)
            return
        }
        // Default file representation preserves full lossless ProRAW quality.
        result = Result { try inbox.store(data) }
        let size = photo.resolvedSettings.rawPhotoDimensions
        Log.camera.debug(
            "RAW \(size.width)×\(size.height) saved: \(ProcessInfo.processInfo.systemUptime - self.started) s")
    }
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(with: result ?? .failure(CameraFailure.noData))
        }
    }
}
