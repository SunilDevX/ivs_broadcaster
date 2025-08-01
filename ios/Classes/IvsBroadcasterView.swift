//
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
//

import AVFoundation
import AmazonIVSBroadcast
import Flutter
import UIKit

// MARK: - Logger Class
class IVSLogger {
    static let shared = IVSLogger()
    private let logQueue = DispatchQueue(label: "ivs-logger-queue", qos: .utility)
    private var logFileURL: URL?
    
    private init() {
        setupLogFile()
    }
    
    private func setupLogFile() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let logsDirectory = documentsPath.appendingPathComponent("IVSLogs")
        
        // Create logs directory if it doesn't exist
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true, attributes: nil)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        
        logFileURL = logsDirectory.appendingPathComponent("ivs_broadcast_\(timestamp).log")
        
        // Log initial setup
        writeToFile("=== IVS Broadcaster Log Started at \(Date()) ===")
        writeToFile("Log file location: \(logFileURL?.path ?? "Unknown")")
        writeToFile("App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")")
        writeToFile("iOS Version: \(UIDevice.current.systemVersion)")
        writeToFile("Device Model: \(UIDevice.current.model)")
        writeToFile("=== Log Setup Complete ===\n")
    }
    
    func log(_ message: String, level: LogLevel = .info, function: String = #function, file: String = #file, line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] [\(level.rawValue)] [\(fileName):\(line)] \(function) - \(message)"
        
        // Print to console for debug builds
        #if DEBUG
        print(logMessage)
        #endif
        
        // Write to file (uncommented for better debugging)
        logQueue.async {
            self.writeToFile(logMessage)
        }
    }
    
    private func writeToFile(_ message: String) {
        guard let logFileURL = logFileURL else { return }
        
        let messageWithNewline = message + "\n"
        
        if let data = messageWithNewline.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                // Append to existing file
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                // Create new file
                try? data.write(to: logFileURL)
            }
        }
    }
    
    func getLogFilePath() -> String? {
        return logFileURL?.path
    }
    
    func getAllLogFiles() -> [String] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let logsDirectory = documentsPath.appendingPathComponent("IVSLogs")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil)
            return files.filter { $0.pathExtension == "log" }.map { $0.path }
        } catch {
            return []
        }
    }
    
    func clearOldLogs() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let logsDirectory = documentsPath.appendingPathComponent("IVSLogs")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.creationDateKey])
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            
            for file in files {
                if let creationDate = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   creationDate < cutoffDate {
                    try? FileManager.default.removeItem(at: file)
                    writeToFile("Deleted old log file: \(file.lastPathComponent)")
                }
            }
        } catch {
            writeToFile("Error cleaning old logs: \(error)")
        }
    }
}

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"
}
 

class IvsBroadcasterView: NSObject, FlutterPlatformView, FlutterStreamHandler,
                          IVSBroadcastSession.Delegate, IVSCameraDelegate,
                          AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate
{
    
    // MARK: - Logger Instance
    private let logger = IVSLogger.shared
    
    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        logger.log("Event sink listener attached")
        _eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        logger.log("Event sink listener cancelled")
        _eventSink = nil
        return nil
    }
    
    func view() -> UIView {
        return previewView
    }
    
    private var _methodChannel: FlutterMethodChannel
    private var _eventChannel: FlutterEventChannel
    var _eventSink: FlutterEventSink?
    private var previewView: UIView
    private var broadcastSession: IVSBroadcastSession?
    
    private var streamKey: String?
    private var rtmpsKey: String?
    
    init(
        _ frame: CGRect,
        viewId: Int64,
        args: Any?,
        messenger: FlutterBinaryMessenger
    ) {
        _methodChannel = FlutterMethodChannel(
            name: "ivs_broadcaster", binaryMessenger: messenger)
        _eventChannel = FlutterEventChannel(
            name: "ivs_broadcaster_event", binaryMessenger: messenger)
        previewView = UIView(frame: frame)
        super.init()
        
        logger.log("IvsBroadcasterView initialized with frame: \(frame), viewId: \(viewId)")
        
        _methodChannel.setMethodCallHandler(onMethodCall)
        _eventChannel.setStreamHandler(self)
        let tapGestureRecognizer = UITapGestureRecognizer(
            target: self, action: #selector(setFocusPoint(_:)))
        let zoomGestureRecognizer = UIPinchGestureRecognizer(
            target: self, action: #selector(setZoom(_:)))
        previewView.addGestureRecognizer(tapGestureRecognizer)
        previewView.addGestureRecognizer(zoomGestureRecognizer)
        
        // Setup audio session interruption notifications
        setupAudioSessionNotifications()
        
        // Clean old logs on initialization
        logger.clearOldLogs()
    }
    
    deinit {
        logger.log("IvsBroadcasterView deallocated")
        NotificationCenter.default.removeObserver(self)
        
        // Cancel all active timers
        audioTimerLock.lock()
        for timer in activeAudioTimers {
            timer.cancel()
        }
        activeAudioTimers.removeAll()
        audioTimerLock.unlock()
    }
    
    // MARK: - Improved Audio/Video Processing Queues with same priority
    private let audioQueue = DispatchQueue(label: "audio-processing-queue", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "video-processing-queue", qos: .userInitiated)
    private var captureSession: AVCaptureSession?
    
    // MARK: - Enhanced Synchronization Properties
    private var baselineAudioPTS: CMTime?
    private var baselineVideoPTS: CMTime?
    private var audioVideoOffset: TimeInterval = 0.0
    private let syncLock = NSLock()
    private var syncCalibrated = false
    private let targetAudioDelay: TimeInterval = 0.050 // 50ms to compensate for video encoding delay
    
    // MARK: - Timer Management (Fixed)
    private var activeAudioTimers: [DispatchSourceTimer] = []
    private let audioTimerLock = NSLock()
    
    // MARK: - Audio Buffer Management
    private var audioBufferCount = 0
    private let maxAudioBufferCount = 3
    private let audioBufferLock = NSLock()
    
    // Keep track of timestamp for debugging
    var videoPTS: CMTime?
    var audioPTS: CMTime?
    
    // MARK: - Improved Audio-Video Synchronization
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let currentPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if output == videoOutput {
            handleVideoSample(sampleBuffer, pts: currentPTS)
        } else if output == audioOutput {
            handleAudioSample(sampleBuffer, pts: currentPTS)
        }
    }
    
    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        syncLock.lock()
        defer { syncLock.unlock() }
        
        self.videoPTS = pts
        
        // Establish baseline if not set
        if !syncCalibrated {
            if baselineVideoPTS == nil {
                baselineVideoPTS = pts
                logger.log("Video baseline PTS established: \(pts.seconds)")
            }
            
            // Wait for both baselines before calibrating
            if let _ = baselineAudioPTS, let _ = baselineVideoPTS {
                calibrateSync()
            }
        }
        
        // Process video immediately (video typically has more processing overhead)
        videoQueue.async {
            self.customImageSource?.onSampleBuffer(sampleBuffer)
        }
    }
    
    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        syncLock.lock()
        let localVideoPTS = self.videoPTS
        syncLock.unlock()
        
        self.audioPTS = pts
        
        // Establish baseline if not set
        syncLock.lock()
        if !syncCalibrated {
            if baselineAudioPTS == nil {
                baselineAudioPTS = pts
                logger.log("Audio baseline PTS established: \(pts.seconds)")
            }
            
            // Wait for both baselines before calibrating
            if let _ = baselineAudioPTS, let _ = baselineVideoPTS {
                calibrateSync()
            }
            syncLock.unlock()
            
            // Process audio normally during calibration
            audioQueue.async {
                self.customAudioSource?.onSampleBuffer(sampleBuffer)
            }
            return
        }
        syncLock.unlock()
        
        // Calculate dynamic delay based on current sync state
        let audioDelay = calculateAudioDelay(audioPTS: pts, videoPTS: localVideoPTS)

        if (audioDelay > 0){
            audioQueue.asyncAfter(deadline: .now() + audioDelay) {
                self.customAudioSource?.onSampleBuffer(sampleBuffer)
            }
        } else {
            audioQueue.async {
                self.customAudioSource?.onSampleBuffer(sampleBuffer)
            }
        }
        
    }
    
    private func calibrateSync() {
        guard let audioBaseline = baselineAudioPTS,
              let videoBaseline = baselineVideoPTS else { return }
        
        // Calculate initial offset between audio and video
        let initialOffset = CMTimeSubtract(videoBaseline, audioBaseline).seconds
        audioVideoOffset = initialOffset + targetAudioDelay
        syncCalibrated = true
        
        logger.log("Sync calibrated - Initial offset: \(initialOffset)s, Target delay: \(targetAudioDelay)s, Total offset: \(audioVideoOffset)s")
    }
    
    private func calculateAudioDelay(audioPTS: CMTime, videoPTS: CMTime?) -> TimeInterval {
        guard let audioBaseline = baselineAudioPTS,
              let videoBaseline = baselineVideoPTS,
              let videoPTS = videoPTS else {
            // If any baseline or videoPTS is missing, return 0 delay
            return 0
        }

        // Calculate relative timestamps from baselines
        let audioRelative = CMTimeSubtract(audioPTS, audioBaseline).seconds
        let videoRelative = CMTimeSubtract(videoPTS, videoBaseline).seconds

        // Calculate how much audio is ahead of video
        let currentDrift = audioRelative - videoRelative

        return currentDrift
    }
    
    // MARK: - Audio Session Management
    private func setupAudioSessionNotifications() {
        logger.log("Setting up audio session notifications")
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionInterrupted),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }
    
    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            logger.log("Invalid audio session interruption notification", level: .error)
            return
        }
        
        switch type {
        case .began:
            logger.log("Audio session interruption began", level: .warning)
            // Handle interruption - pause if needed
        case .ended:
            logger.log("Audio session interruption ended", level: .info)
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    logger.log("Resuming audio session after interruption", level: .info)
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        logger.log("Audio session resumed successfully", level: .info)
                    } catch {
                        logger.log("Failed to resume audio session: \(error)", level: .error)
                    }
                }
            }
        @unknown default:
            logger.log("Unknown audio session interruption type: \(typeValue)", level: .warning)
            break
        }
    }
    
    @objc private func audioSessionRouteChanged(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            logger.log("Invalid audio route change notification", level: .error)
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            logger.log("Audio route changed: New device available", level: .info)
        case .oldDeviceUnavailable:
            logger.log("Audio route changed: Old device unavailable", level: .info)
        case .categoryChange:
            logger.log("Audio route changed: Category change", level: .info)
        case .override:
            logger.log("Audio route changed: Override", level: .info)
        case .wakeFromSleep:
            logger.log("Audio route changed: Wake from sleep", level: .info)
        case .noSuitableRouteForCategory:
            logger.log("Audio route changed: No suitable route for category", level: .warning)
        case .routeConfigurationChange:
            logger.log("Audio route changed: Route configuration change", level: .info)
        case .unknown:
            logger.log("Audio route changed: Unknown reason", level: .warning)
        @unknown default:
            logger.log("Audio route changed: Unknown reason (\(reasonValue))", level: .warning)
        }
    }
    
    // MARK: - Enhanced Audio Session Configuration
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetooth, .defaultToSpeaker])
            try audioSession.setPreferredSampleRate(44100)
            
            // Increase buffer duration for more stable sync
            try audioSession.setPreferredIOBufferDuration(0.040) // 40ms for better stability
            try audioSession.setActive(true)
            
            logger.log("Audio session configured: 40ms buffer, 44.1kHz sample rate")
        } catch {
            logger.log("Failed to configure audio session: \(error)", level: .error)
        }
    }
    
    func checkOrGetPermission(
        for mediaType: AVMediaType, _ result: @escaping (Bool) -> Void
    ) {
        logger.log("Checking permission for media type: \(mediaType.rawValue)")
        
        func mainThreadResult(_ success: Bool) {
            DispatchQueue.main.async {
                self.logger.log("Permission result for \(mediaType.rawValue): \(success)")
                result(success)
            }
        }
        
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            logger.log("Permission already authorized for \(mediaType.rawValue)")
            mainThreadResult(true)
        case .notDetermined:
            logger.log("Permission not determined for \(mediaType.rawValue), requesting access")
            AVCaptureDevice.requestAccess(for: mediaType) {
                self.logger.log("Permission request result for \(mediaType.rawValue): \($0)")
                mainThreadResult($0)
            }
        case .denied:
            logger.log("Permission denied for \(mediaType.rawValue)", level: .warning)
            mainThreadResult(false)
        case .restricted:
            logger.log("Permission restricted for \(mediaType.rawValue)", level: .warning)
            mainThreadResult(false)
        @unknown default:
            logger.log("Unknown permission status for \(mediaType.rawValue)", level: .warning)
            mainThreadResult(false)
        }
    }
    
    func attachCameraPreview(container: UIView, preview: UIView) {
        logger.log("Attaching camera preview to container")
        // Clear current view, and then attach the new view.
        container.subviews.forEach { $0.removeFromSuperview() }
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(
                equalTo: container.topAnchor, constant: 0),
            preview.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: 0),
            preview.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 0),
            preview.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: 0),
        ])
        logger.log("Camera preview attached successfully")
    }
    
    func onZoomCamera(value: Double) {
        logger.log("Zoom camera requested with value: \(value)")
        
        guard let captureSession = self.captureSession, captureSession.isRunning
        else {
            logger.log("Cannot zoom camera - capture session not running", level: .warning)
            return
        }
        
        do {
            try videoDevice?.lockForConfiguration()
        } catch {
            logger.log("Failed to lock configuration for zoom: \(error)", level: .error)
            self.videoDevice?.unlockForConfiguration()
            return
        }
        
        let maxZoom = self.videoDevice?.activeFormat.videoMaxZoomFactor ?? 1.0
        let zoom = max(1.0, min(value, maxZoom))
        self.currentZoomFactor = zoom
        self.videoDevice?.videoZoomFactor = zoom
        self.videoDevice?.unlockForConfiguration()
        
        logger.log("Camera zoom set to: \(zoom) (requested: \(value), max: \(maxZoom))")
    }
    
    // Define constants for method names
    private let METHOD_START_PREVIEW = "startPreview"
    private let METHOD_START_BROADCAST = "startBroadcast"
    private let METHOD_GET_CAMERA_ZOOM_FACTOR = "getCameraZoomFactor"
    private let METHOD_ZOOM_CAMERA = "zoomCamera"
    private let METHOD_UPDATE_CAMERA_LENS = "updateCameraLens"
    private let METHOD_MUTE = "mute"
    private let METHOD_IS_MUTED = "isMuted"
    private let METHOD_CHANGE_CAMERA = "changeCamera"
    private let METHOD_GET_AVAILABLE_CAMERA_LENS = "getAvailableCameraLens"
    private let METHOD_STOP_BROADCAST = "stopBroadcast"
    private let METHOD_SET_FOCUS_MODE = "setFocusMode"
    private let METHOD_CAPTURE_VIDEO = "captureVideo"
    private let METHOD_STOP_VIDEO_CAPTURE = "stopVideoCapture"
    private let METHOD_SEND_TIME_METADATA = "sendTimeMetaData"
    private let METHOD_SET_FOCUS_POINT = "setFocusPoint"
    private let METHOD_GET_CAMERA_BRIGHTNESS = "getCameraBrightness"
    private let METHOD_SET_CAMERA_BRIGHTNESS = "setCameraBrightness"
    private let METHOD_GET_LOG_FILE_PATH = "getLogFilePath"
    private let METHOD_GET_ALL_LOG_FILES = "getAllLogFiles"
    
    private var initialZoomScale: CGFloat = 1.0
    private var currentZoomFactor: CGFloat = 1.0
    
    // Define constants for argument keys
    private let ARG_IMGSET = "imgset"
    private let ARG_STREAM_KEY = "streamKey"
    private let ARG_QUALITY = "quality"
    private let ARG_AUTO_RECONNECT = "autoReconnect"
    private let ARG_ZOOM = "zoom"
    private let ARG_LENS = "lens"
    private let ARG_TYPE = "type"
    private let ARG_SECONDS = "seconds"
    private let ARG_BRIGHTNESS = "brightness"
    
    func onMethodCall(call: FlutterMethodCall, result: FlutterResult) {
        logger.log("Method call received: \(call.method)")
        
        switch call.method {
        case METHOD_START_PREVIEW:
            let args = call.arguments as? [String: Any]
            let url = args?[ARG_IMGSET] as? String
            let key = args?[ARG_STREAM_KEY] as? String
            let quality = args?[ARG_QUALITY] as? String
            let autoReconnect = args?[ARG_AUTO_RECONNECT] as? Bool
            logger.log("Starting preview with URL: \(url ?? "nil"), Quality: \(quality ?? "nil"), AutoReconnect: \(autoReconnect ?? false)")
            setupSession(url!, key!, quality!, autoReconnect ?? false)
            result(true)
            
        case METHOD_START_BROADCAST:
            logger.log("Starting broadcast")
            startBroadcast()
            result(true)
            
        case METHOD_GET_CAMERA_ZOOM_FACTOR:
            let zoomData = getCameraZoomFactor()
            logger.log("Camera zoom factor requested: \(zoomData)")
            result(zoomData)
        
        case METHOD_GET_CAMERA_BRIGHTNESS:
            let brightnessData = getCameraBrightness()
            logger.log("Camera brightness requested: \(brightnessData)")
            result(brightnessData)
            
        case METHOD_SET_CAMERA_BRIGHTNESS:
            let args = call.arguments as? [String: Any]
            if let brightness = args?[ARG_BRIGHTNESS] as? Int {
                logger.log("Setting camera brightness to: \(brightness)")
                updateBrightness(brightness)
            }
            result("Success")
            
        case METHOD_ZOOM_CAMERA:
            let args = call.arguments as? [String: Any]
            let zoomValue = args?[ARG_ZOOM] as? Double ?? 0.0
            onZoomCamera(value: zoomValue)
            result("Success")
            
        case METHOD_UPDATE_CAMERA_LENS:
            let args = call.arguments as? [String: Any]
            let lens = args?[ARG_LENS] as? String ?? "0"
            logger.log("Updating camera lens to: \(lens)")
            let data = updateCameraType(lens)
            result(data)
            
        case METHOD_MUTE:
            logger.log("Mute/unmute requested")
            applyMute()
            result(true)
            
        case METHOD_IS_MUTED:
            logger.log("Mute status requested: \(isMuted)")
            result(isMuted)
            
        case METHOD_CHANGE_CAMERA:
            let args = call.arguments as? [String: Any]
            let type = args?[ARG_TYPE] as? String
            logger.log("Change camera requested to: \(type ?? "nil")")
            changeCamera(type: type!)
            result(true)
            
        case METHOD_GET_AVAILABLE_CAMERA_LENS:
            if #available(iOS 13.0, *) {
                let lenses = getAvailableCameraLens()
                logger.log("Available camera lenses: \(lenses)")
                result(lenses)
            } else {
                logger.log("Available camera lenses not supported on iOS < 13.0", level: .warning)
                result([])
            }
            
        case METHOD_STOP_BROADCAST:
            logger.log("Stop broadcast requested")
            stopBroadCast()
            result(true)
            
        case METHOD_SET_FOCUS_MODE:
            let args = call.arguments as? [String: Any]
            let type = args?[ARG_TYPE] as? String
            logger.log("Set focus mode requested: \(type ?? "nil")")
            let focusResult = setFocusMode(type!)
            result(focusResult)
            
        case METHOD_CAPTURE_VIDEO:
            let args = call.arguments as? [String: Any]
            let seconds = args?[ARG_SECONDS] as? Int
            logger.log("Capture video requested for \(seconds ?? 0) seconds")
            captureVideo(seconds!)
            result("Starting Video Recording")
            
        case METHOD_STOP_VIDEO_CAPTURE:
            logger.log("Stop video capture requested")
            stopVideoCapturing()
            result(true)
            
        case METHOD_SEND_TIME_METADATA:
            let args = call.arguments as! String
            logger.log("Send timed metadata: \(args)")
            sendMetaData(metadata: args)
            result("")
            
        case METHOD_GET_LOG_FILE_PATH:
            let logPath = logger.getLogFilePath()
            logger.log("Log file path requested: \(logPath ?? "nil")")
            result(logPath)
            
        case METHOD_GET_ALL_LOG_FILES:
            let allLogs = logger.getAllLogFiles()
            logger.log("All log files requested: \(allLogs)")
            result(allLogs)
            
        default:
            logger.log("Unknown method call: \(call.method)", level: .warning)
            result(FlutterMethodNotImplemented)
        }
    }
    
    func sendMetaData( metadata:String){
        logger.log("Sending timed metadata: \(metadata)")
        do {
            try self.broadcastSession?.sendTimedMetadata(metadata);
            logger.log("Timed metadata sent successfully")
        } catch {
            logger.log("Unable to send timed metadata: \(error)", level: .error)
        }
    }
    
    func stopVideoCapturing() {
        guard let movieOutput = movieOutput, movieOutput.isRecording else {
            logger.log("No active recording to stop", level: .warning)
            return
        }
        
        logger.log("Stopping video recording")
        movieOutput.stopRecording()
        captureSession?.removeOutput(movieOutput)
        self.movieOutput = nil
        logger.log("Video recording stopped successfully")
    }
    
    private var movieOutput: AVCaptureMovieFileOutput?
    
    func captureVideo(_ seconds: Int) {
        guard let captureSession = self.captureSession, captureSession.isRunning
        else {
            logger.log("Capture session is not running - cannot start video recording", level: .error)
            return
        }
        
        logger.log("Starting video capture for \(seconds) seconds")
        
        // Define output file URL
        let outputFilePath = NSTemporaryDirectory() + "output.mov"
        let outputURL = URL(fileURLWithPath: outputFilePath)
        if FileManager.default.fileExists(atPath: outputFilePath) {
            do {
                try FileManager.default.removeItem(atPath: outputFilePath)
                logger.log("Removed existing output file")
            } catch {
                logger.log("Error removing existing file: \(error.localizedDescription)", level: .error)
                return
            }
        }
        
        // Set up movie output
        let movieOutput = AVCaptureMovieFileOutput()
        self.movieOutput = movieOutput
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            logger.log("Movie output added to capture session")
        } else {
            logger.log("Cannot add movie output to capture session", level: .error)
            return
        }
        
        // Start recording
        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        logger.log("Video recording started, output URL: \(outputURL)")
        
        var data = [String: Any]()
        data = [
            "isRecording": true,
            "videoPath": "",
        ]
        if self._eventSink != nil {
            self._eventSink!(data)
        }
        
        // Stop recording after the specified duration
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            [weak self] in
            self?.logger.log("Auto-stopping video recording after \(seconds) seconds")
            movieOutput.stopRecording()
            self?.captureSession?.removeOutput(movieOutput)
        }
    }
    
    // Start Broadcasting with rtmps and stream key
    func startBroadcast() {
        guard let rtmpsKey = rtmpsKey, let streamKey = streamKey else {
            logger.log("Cannot start broadcast - missing RTMPS key or stream key", level: .error)
            return
        }
        
        logger.log("Starting broadcast with RTMPS: \(rtmpsKey)")
        
        do {
            try self.broadcastSession?.start(
                with: URL(string: rtmpsKey)!, streamKey: streamKey)
            logger.log("Broadcast started successfully")
        } catch {
            logger.log("Unable to start streaming: \(error)", level: .error)
        }
    }
    
    func normalizePoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        return CGPoint(x: point.x / size.width, y: point.y / size.height)
    }
    
    @objc func setZoom(_ gestureRecognizer: UIPinchGestureRecognizer) {
        guard let videoDevice = videoDevice else {
            logger.log("Video device unavailable for zoom gesture", level: .warning)
            return
        }
        
        let numberOfTouches = gestureRecognizer.numberOfTouches
        
        switch gestureRecognizer.state {
        case .began:
            initialZoomScale = currentZoomFactor
            logger.log("Zoom gesture began with initial scale: \(initialZoomScale)")
        case .changed:
            do {
                try videoDevice.lockForConfiguration()
                
                let maxZoom = 10.0
                let minZoom: CGFloat = 1.0
                
                // Calculate new zoom factor
                let desiredZoomFactor = initialZoomScale * gestureRecognizer.scale
                let clampedZoomFactor = max(minZoom, min(desiredZoomFactor, maxZoom))
                
                // Apply smooth zoom transition
                let zoomRamp = 1.0
                let smoothZoomFactor = currentZoomFactor + (clampedZoomFactor - currentZoomFactor) * zoomRamp
                let data = ["zoom": smoothZoomFactor]
                self._eventSink!(data)
                videoDevice.videoZoomFactor = smoothZoomFactor
                currentZoomFactor = smoothZoomFactor
                
                videoDevice.unlockForConfiguration()
                
            } catch {
                logger.log("Failed to set zoom factor: \(error.localizedDescription)", level: .error)
            }
            
        case .ended:
            currentZoomFactor = videoDevice.videoZoomFactor
            logger.log("Zoom gesture ended with final zoom: \(currentZoomFactor)")
            
        default:
            break
        }
    }
    
    @objc func updateBrightness(_ brightness: Int) {
        guard let videoDevice = videoDevice else {
            logger.log("Video device unavailable for brightness adjustment", level: .warning)
            return
        }
        
        let minBias = videoDevice.minExposureTargetBias
        let maxBias = videoDevice.maxExposureTargetBias
        let clampedBias = max(min(Float(brightness), maxBias), minBias)
        
        logger.log("Setting brightness to: \(brightness) (clamped: \(clampedBias), range: \(minBias) to \(maxBias))")
        
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.setExposureTargetBias(clampedBias) { _ in }
            videoDevice.unlockForConfiguration()
            let data = ["exposureBias": clampedBias]
            self._eventSink?(data)
            logger.log("Brightness set successfully")
        } catch {
            logger.log("Error setting exposure bias: \(error)", level: .error)
        }
    }
    
    var focusPoint: CGPoint?
    
    @objc func setFocusPoint(_ gestureRecognizer: UITapGestureRecognizer) {
        guard let videoDevice = videoDevice else {
            logger.log("No video device available for focus point", level: .warning)
            return
        }
        
        if videoDevice.focusMode == .continuousAutoFocus {
            logger.log("Camera is on continuous auto focus - set it to manual focus first", level: .warning)
            return
        }
        
        let tapPoint = gestureRecognizer.location(in: previewView)
        let originalPoint = CGPoint(x: tapPoint.x, y: tapPoint.y)
        focusPoint = originalPoint
        let size = CGSize(
            width: self.previewView.frame.width,
            height: self.previewView.frame.height)
        let normalizedPoint = normalizePoint(originalPoint, size: size)
        
        logger.log("Setting focus point to: \(originalPoint) (normalized: \(normalizedPoint))")
        
        do {
            try videoDevice.lockForConfiguration()
            
            if videoDevice.isFocusPointOfInterestSupported {
                videoDevice.focusPointOfInterest = normalizedPoint
                videoDevice.focusMode = .autoFocus
                logger.log("Focus point set successfully")
            } else {
                logger.log("Focus point selection not supported", level: .warning)
                return
            }
            videoDevice.unlockForConfiguration()
            let data = ["focusPoint": "\(tapPoint.x)_\(tapPoint.y)"]
            self._eventSink!(data)
            
        } catch {
            logger.log("Error setting focus point: \(error)", level: .error)
            return
        }
    }
    
    func setFocusMode(_ type: String) -> Bool {
        guard let videoDevice = videoDevice else {
            logger.log("Video device unavailable for focus mode change", level: .warning)
            return false
        }
        
        let focusMode: AVCaptureDevice.FocusMode
        switch type {
        case "0":
            focusMode = .locked
        case "1":
            focusMode = .autoFocus
        case "2":
            focusMode = .continuousAutoFocus
        default:
            logger.log("Invalid focus mode type: \(type)", level: .error)
            return false
        }
        
        logger.log("Setting focus mode to: \(focusMode)")
        
        if videoDevice.isFocusModeSupported(focusMode) {
            do {
                try videoDevice.lockForConfiguration()
                videoDevice.focusMode = focusMode
                videoDevice.unlockForConfiguration()
                logger.log("Focus mode set successfully")
                return true
            } catch {
                logger.log("Error setting focus mode: \(error)", level: .error)
                return false
            }
        } else {
            logger.log("Focus mode not supported: \(focusMode)", level: .warning)
            return false
        }
    }
    
    func getCameraZoomFactor() -> [String: Any] {
        var max = 0
        var min = 0
        max = Int(self.videoDevice?.maxAvailableVideoZoomFactor ?? 0)
        min = Int(self.videoDevice?.minAvailableVideoZoomFactor ?? 0)
        let result = ["min": min, "max": max]
        logger.log("Camera zoom factor: \(result)")
        return result
    }
    
    func getCameraBrightness() -> [String: Any] {
        guard let videoDevice = self.videoDevice else {
            logger.log("Video device unavailable for brightness query", level: .warning)
            return [:]
        }
        
        let result: [String: Any]
        if videoDevice.isAdjustingExposure {
            result = ["min":0, "max":0, "value":0]
        } else {
            result = [
                "min": Int(videoDevice.minExposureTargetBias),
                "max": Int(videoDevice.maxExposureTargetBias),
                "value": Int(videoDevice.exposureTargetBias)
            ]
        }
        
        logger.log("Camera brightness: \(result)")
        return result
    }
    
    func changeCamera(type: String) {
        logger.log("Changing camera to type: \(type)")
        
        if let cameraPosition = CameraPosition(string: type) {
            switch cameraPosition {
            case .front:
                updateToFrontCamera()
            case .back:
                updateToBackCamera()
            }
        } else {
            logger.log("Invalid camera position string: \(type)", level: .error)
        }
    }
    
    func updateToBackCamera() {
        logger.log("Updating to back camera")
        
        do {
            guard let captureSession = self.captureSession,
                  captureSession.isRunning
            else {
                logger.log("Capture session not running - cannot switch to back camera", level: .warning)
                return
            }
            
            self.captureSession?.beginConfiguration()
            guard
                let currentCameraInput = self.captureSession?.inputs.first
                    as? AVCaptureDeviceInput
            else {
                logger.log("No current camera input found", level: .error)
                return
            }
            
            let videoDevice = AVCaptureDevice.default(for: .video)
            try addInputDevice(videoDevice, currentCameraInput)
            self.captureSession?.commitConfiguration()
            logger.log("Successfully switched to back camera")
            
        } catch {
            logger.log("Failed to switch to back camera: \(error)", level: .error)
            return
        }
    }
    
    func updateToFrontCamera() {
        logger.log("Updating to front camera")
        
        do {
            guard let captureSession = self.captureSession,
                  captureSession.isRunning
            else {
                logger.log("Capture session not running - cannot switch to front camera", level: .warning)
                return
            }
            
            self.captureSession?.beginConfiguration()
            guard
                let currentCameraInput = self.captureSession?.inputs.first
                    as? AVCaptureDeviceInput
            else {
                logger.log("No current camera input found", level: .error)
                return
            }
            
            let videoDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .front)
            try addInputDevice(videoDevice, currentCameraInput)
            self.captureSession?.commitConfiguration()
            logger.log("Successfully switched to front camera")
            
        } catch {
            logger.log("Failed to switch to front camera: \(error)", level: .error)
            return
        }
    }
    
    private var isMuted = false {
        didSet {
            logger.log("Mute state changed to: \(isMuted)")
            applyMute()
        }
    }
    
    private var attachedCamera: IVSDevice? {
        didSet {
            logger.log("Attached camera changed")
            if let preview = try? (attachedCamera as? IVSImageDevice)?
                .previewView(with: .fill)
            {
                attachCameraPreview(container: previewView, preview: preview)
            } else {
                previewView.subviews.forEach { $0.removeFromSuperview() }
            }
        }
    }
    
    private var attachedMicrophone: IVSDevice? {
        didSet {
            logger.log("Attached microphone changed")
            applyMute()
        }
    }
    
    func stopBroadCast() {
        logger.log("Stopping broadcast")
        
        // Cancel any pending audio delay timers
        audioTimerLock.lock()
        for timer in activeAudioTimers {
            timer.cancel()
        }
        activeAudioTimers.removeAll()
        audioTimerLock.unlock()
        
        // Reset synchronization state
        syncLock.lock()
        baselineAudioPTS = nil
        baselineVideoPTS = nil
        audioVideoOffset = 0.0
        syncCalibrated = false
        syncLock.unlock()
        
        self.captureSession?.stopRunning()
        broadcastSession?.stop()
        broadcastSession = nil
        if self._eventSink != nil {
            self._eventSink?(["state": "DISCONNECTED"])
        }
        previewView.subviews.forEach { $0.removeFromSuperview() }
        
        logger.log("Broadcast stopped successfully")
    }
    
    private func applyMute() {
        guard
            let currentAudioInput = self.captureSession?.inputs.first(where: {
                ($0 as? AVCaptureDeviceInput)?.device.position == .unspecified
            }) as? AVCaptureDeviceInput
        else {
            logger.log("Unable to get current audio input for mute operation", level: .warning)
            return
        }
        
        if isMuted {
            self.captureSession?.removeInput(currentAudioInput)
            logger.log("Audio input removed (muted)")
        } else {
            if self.captureSession?.canAddInput(currentAudioInput) == true {
                self.captureSession?.addInput(currentAudioInput)
                logger.log("Audio input added (unmuted)")
            }
        }
    }
    
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var customImageSource: IVSCustomImageSource?
    private var customAudioSource: IVSCustomAudioSource?
    private var videoDevice: AVCaptureDevice?
    private var audioDevice: AVCaptureDevice?
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer?
    
    private func setupSession(
        _ url: String,
        _ key: String,
        _ quality: String,
        _ autoReconnect: Bool
    ) {
        logger.log("Setting up session with URL: \(url), Quality: \(quality), AutoReconnect: \(autoReconnect)")
        
        do {
            self.streamKey = key
            self.rtmpsKey = url
            IVSBroadcastSession.applicationAudioSessionStrategy = .noAction
            let config = try createBroadcastConfiguration(for: quality)
            let customSlot = IVSMixerSlotConfiguration()
            customSlot.size = CGSize(width: 1920, height: 1080)
            customSlot.position = CGPoint(x: 0, y: 0)
            customSlot.preferredAudioInput = .userAudio
            customSlot.preferredVideoInput = .userImage
            let reconnect = IVSBroadcastAutoReconnectConfiguration()
            reconnect.enabled = autoReconnect
            config.autoReconnect = reconnect
            try customSlot.setName("custom-slot")
            config.mixer.slots = [customSlot]
            let broadcastSession = try IVSBroadcastSession(
                configuration: config,
                descriptors: nil,
                delegate: self)
            let customImageSource = broadcastSession.createImageSource(withName: "custom-image")
            let customAudioSource = broadcastSession.createAudioSource(withName: "custom-audio")
            broadcastSession.attach(customAudioSource, toSlotWithName: "custom-slot")
            broadcastSession.attach(customImageSource, toSlotWithName: "custom-slot")
            self.customImageSource = customImageSource
            self.customAudioSource = customAudioSource
            self.broadcastSession = broadcastSession
            
            logger.log("IVS broadcast session configured successfully")
            startSession()
        } catch {
            logger.log("Unable to setup session: \(error.localizedDescription)", level: .error)
        }
    }
    
    @available(iOS 13.0, *)
    func getAvailableCameraLens() -> [Int] {
        logger.log("Getting available camera lenses")
        
        var lenses = [Int]()
        lenses.append(8)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTelephotoCamera,
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInDualWideCamera,
            ], mediaType: .video, position: .unspecified)
        for device in discoverySession.devices {
            switch device.deviceType {
            case .builtInTelephotoCamera:
                lenses.append(3)
                logger.log("Device has a built-in telephoto camera")
            default:
                logger.log("Device has camera type: \(device.deviceType)")
            }
        }
        lenses = Array(Set(lenses))
        logger.log("Available camera lenses: \(lenses)")
        return lenses
    }
    
    func updateCameraType(_ cameraType: String) -> String {
        logger.log("Updating camera type to: \(cameraType)")
        
        guard let captureSession = self.captureSession, captureSession.isRunning
        else {
            logger.log("Session not running - cannot update camera type", level: .warning)
            return "Session Not Running"
        }
        
        self.captureSession?.beginConfiguration()
        guard
            let currentCameraInput = self.captureSession?.inputs.first(where: {
                ($0 as? AVCaptureDeviceInput)?.device.position != .unspecified
            }) as? AVCaptureDeviceInput
        else {
            logger.log("Unable to get current camera input", level: .error)
            return ""
        }
        
        do {
            var videoDevice: AVCaptureDevice?
            var deviceName = ""
            
            switch cameraType {
            case "0":
                if #available(iOS 13.0, *) {
                    videoDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
                    deviceName = "dual camera"
                } else {
                    return ("Device is not compatible to set dual camera")
                }
            case "1":
                if #available(iOS 10.0, *) {
                    videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    deviceName = "wide angle camera"
                } else {
                    return ("Device is not compatible to set wideangle camera")
                }
            case "2":
                if #available(iOS 13.0, *) {
                    videoDevice = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                    deviceName = "triple camera"
                } else {
                    return ("Device is not compatible to set triple camera")
                }
            case "3":
                if #available(iOS 10.0, *) {
                    videoDevice = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
                    deviceName = "telephoto camera"
                } else {
                    return ("Device is not compatible to set tele photo camera")
                }
            case "4":
                if #available(iOS 13.0, *) {
                    videoDevice = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    deviceName = "dual wide camera"
                } else {
                    return ("Device is not compatible to set dual wide camera")
                }
            case "5":
                if #available(iOS 11.1, *) {
                    videoDevice = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .back)
                    deviceName = "TrueDepth camera"
                } else {
                    return ("Device is not compatible to set truedepth camera")
                }
            case "6":
                if #available(iOS 13.0, *) {
                    videoDevice = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                    deviceName = "ultra wide camera"
                } else {
                    return ("Device is not compatible to set utra wide camera")
                }
            case "7":
                if #available(iOS 15.4, *) {
                    videoDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
                    deviceName = "LiDAR depth camera"
                } else {
                    return ("Device is not compatible to set lidardepthCamera")
                }
            case "8":
                videoDevice = AVCaptureDevice.default(for: .video)
                deviceName = "default camera"
            default:
                logger.log("Unknown camera type: \(cameraType)", level: .error)
                return "Unknown camera type"
            }
            
            try addInputDevice(videoDevice, currentCameraInput)
            logger.log("Successfully updated to \(deviceName)")
            return "Configuration Updated"
            
        } catch {
            logger.log("Device is not compatible: \(error)", level: .error)
            return "Device is not compatible"
        }
    }
    
    enum CameraInputError: Error {
        case invalidDevice
    }
    
    func addInputDevice(
        _ device: AVCaptureDevice?, _ currentCameraInput: AVCaptureDeviceInput
    ) throws {
        
        guard let validDevice = device else {
            logger.log("Invalid device provided for camera input", level: .error)
            self.captureSession?.commitConfiguration()
            throw CameraInputError.invalidDevice
        }
        
        logger.log("Adding new camera input device: \(validDevice.localizedName)")
        
        let newCameraInput = try AVCaptureDeviceInput(device: validDevice)
        self.captureSession?.removeInput(currentCameraInput)
        if self.captureSession?.canAddInput(newCameraInput) ?? false {
            self.captureSession?.addInput(newCameraInput)
            logger.log("New camera input added successfully")
        } else {
            self.captureSession?.addInput(currentCameraInput)
            logger.log("Failed to add new camera input, reverted to previous", level: .warning)
        }
        self.videoDevice = validDevice
        self.captureSession?.commitConfiguration()
    }
    
    // MARK: - Enhanced startSession with Reset sync when session starts
    func startSession() {
        logger.log("Starting capture session")
        
        // Reset synchronization state
        syncLock.lock()
        baselineAudioPTS = nil
        baselineVideoPTS = nil
        audioVideoOffset = 0.0
        syncCalibrated = false
        syncLock.unlock()
        
        let captureSession = AVCaptureSession()
        self.captureSession = captureSession
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        
        // Video setup
        if let videoDevice = AVCaptureDevice.default(for: .video),
           let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
           captureSession.canAddInput(videoInput) {
            
            logger.log("Video device: \(videoDevice.localizedName)")
            
            self.videoDevice = videoDevice
            captureSession.addInput(videoInput)
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            
            // Enable automatic frame dropping to maintain sync
            videoOutput.alwaysDiscardsLateVideoFrames = true
            
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
                self.videoOutput = videoOutput
                if let connection = videoOutput.connections.first {
                    connection.videoOrientation = .landscapeRight
                    connection.isVideoMirrored = false
                    if #available(iOS 13.0, *) {
                        connection.preferredVideoStabilizationMode = .cinematicExtended
                    }
                }
                logger.log("Video output configured successfully")
            }
            
            // Configure consistent frame rate
            do {
                try videoDevice.lockForConfiguration()
                videoDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 30)
                videoDevice.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 30)
                videoDevice.unlockForConfiguration()
                logger.log("Video frame rate set to 30 FPS")
            } catch {
                logger.log("Error setting frame rate: \(error)", level: .error)
            }
        } else {
            logger.log("Failed to setup video device", level: .error)
        }
        
        // Audio setup with improved configuration
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            
            logger.log("Audio device: \(audioDevice.localizedName)")
            
            self.audioDevice = audioDevice
            captureSession.addInput(audioInput)
            
            // Configure audio session with improved settings
            configureAudioSession()
            
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
                self.audioOutput = audioOutput
                logger.log("Audio output configured successfully")
            }
        } else {
            logger.log("Failed to setup audio device", level: .error)
        }
        
        captureSession.commitConfiguration()
        logger.log("Capture session configuration completed")
        
        // Setup preview layer
        DispatchQueue.main.async {
            guard let session = self.captureSession else { return }
            let videoPreviewLayer = AVCaptureVideoPreviewLayer(session: session)
            videoPreviewLayer.videoGravity = .resizeAspectFill
            videoPreviewLayer.frame = self.previewView.bounds
            videoPreviewLayer.connection?.videoOrientation = .landscapeRight
            self.previewView.layer.addSublayer(videoPreviewLayer)
            self.logger.log("Video preview layer added")
        }
        
        // Start session on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
            self.logger.log("Capture session started running")
        }
    }
    
    func broadcastSession(
        _ session: IVSBroadcastSession,
        didChange state: IVSBroadcastSession.State
    ) {
        logger.log("IVSBroadcastSession state changed to: \(state)")
        self.sendMetaData(metadata: "Stream \(getName(state)) at \(Date())")
        DispatchQueue.main.async {
            var data = [String: String]()
            switch state {
            case .invalid:
                data = ["state": "INVALID"]
            case .connecting:
                data = ["state": "CONNECTING"]
            case .connected:
                data = ["state": "CONNECTED"]
                
            case .disconnected:
                data = ["state": "DISCONNECTED"]
            case .error:
                data = ["state": "ERROR"]
            @unknown default:
                data = ["state": "INVALID"]
            }
            self.sendEvent(data)
        }
    }
    
    func getName(_ state: IVSBroadcastSession.State) -> String {
        switch state {
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .error:
            return "Error"
        case .invalid:
            return "InValid"
        }
    }
    
    func broadcastSession(
        _ session: IVSBroadcastSession,
        didChange state: IVSBroadcastSession.RetryState
    ) {
        logger.log("IVS retry state changed to: \(state.rawValue)")
        var data = [String: Any]()
        data = ["retrystate": state.rawValue]
        self._eventSink?(data)
    }
    
    func sendEvent(_ event: Any) {
        DispatchQueue.main.async {
            if self._eventSink != nil {
                self._eventSink!(event)
            }
        }
    }
    
    func broadcastSession(
        _ session: IVSBroadcastSession, didEmitError error: Error
    ) {
        logger.log("Broadcast session error: \(error.localizedDescription)", level: .error)
        DispatchQueue.main.async {
            let data = ["error": error.localizedDescription]
            self.sendEvent(data)
        }
    }
    
    func broadcastSession(
        _ session: IVSBroadcastSession,
        transmissionStatisticsChanged statistics: IVSTransmissionStatistics
    ) {
        let quality = statistics.broadcastQuality.rawValue
        let health = statistics.networkHealth.rawValue
        
        // Log transmission statistics occasionally to avoid spam
        if Int(Date().timeIntervalSince1970) % 2 == 0 {
            sendMetaData(metadata: "Transmission stats - Measured: \(statistics.measuredBitrate), Quality: \(getQualityName(statistics.broadcastQuality)), Network: \(getHealthName(statistics.networkHealth))")
            logger.log("Transmission stats - Recommended: \(statistics.recommendedBitrate), Measured: \(statistics.measuredBitrate), Quality: \(quality), Network: \(health)", level: .debug)
        }
        
        var data = [String: Any]()
        data = ["quality": quality, "network": health]
        self._eventSink?(data)
    }
}

func getHealthName(_ quality: IVSTransmissionStatistics.NetworkHealth) -> String {
     switch quality {
     case .bad:
         return "Bad"
     case .excellent:
        return "Excellent"
     case .high:
         return "High"
     case .low:
         return "Low"
     case .medium:
         return "Medium"
     @unknown default:
        return "Unknown"
    }
}

func getQualityName(_ quality: IVSTransmissionStatistics.BroadcastQuality) -> String {
     switch quality {
     case .low:
        return "Low"
    case .medium:
        return "Medium"
    case .high:
        return "High"
     case .nearMaximum:
         return "Near Maximum"
     case .nearMinimum:
         return "Near Minimum"
     @unknown default:
        return "Unknown"
    }
}

// Store the last known orientation
var lastKnownOrientation: AVCaptureVideoOrientation?

extension IvsBroadcasterView: IVSMicrophoneDelegate {
    func underlyingInputSourceChanged(
        for microphone: IVSMicrophone,
        toInputSource inputSource: IVSDeviceDescriptor?
    ) {
        logger.log("Microphone input source changed")
        self.attachedMicrophone = microphone
    }
    
    // Enhanced Broadcast Configuration with better audio settings
    func createBroadcastConfiguration(for resolution: String) throws -> IVSBroadcastConfiguration {
        logger.log("Creating broadcast configuration for resolution: \(resolution)")
        
        let config = IVSBroadcastConfiguration()
        switch resolution {
        case "360":
            try config.video.setSize(CGSize(width: 640, height: 360))
            try config.video.setMaxBitrate(1_000_000)
            try config.video.setMinBitrate(500_000)
            try config.video.setInitialBitrate(800_000)
            logger.log("Video config: 640x360, bitrate: 500k-1M (init: 800k)")
        case "720":
            try config.video.setSize(CGSize(width: 1280, height: 720))
            try config.video.setMaxBitrate(3_500_000)
            try config.video.setMinBitrate(1_500_000)
            try config.video.setInitialBitrate(2_500_000)
            logger.log("Video config: 1280x720, bitrate: 1.5M-3.5M (init: 2.5M)")
        case "1080":
            try config.video.setSize(CGSize(width: 1920, height: 1080))
            try config.video.setMaxBitrate(6_000_000)
            try config.video.setMinBitrate(4_000_000)
            try config.video.setInitialBitrate(5_000_000)
            logger.log("Video config: 1920x1080, bitrate: 4M-6M (init: 5M)")
        default:
            try config.video.setSize(CGSize(width: 1920, height: 1080))
            try config.video.setMaxBitrate(8_500_000)  // 8.5 Mbps
            try config.video.setMinBitrate(2_500_000)  // 2.5 Mbps
            try config.video.setInitialBitrate(5_000_000)  // 5 Mbps
            try config.video.setTargetFramerate(30)
            try config.video.setKeyframeInterval(2)
            logger.log("Video config: 1920x1080 (default), bitrate: 2.5M-8.5M (init: 5M), 30fps")
        } 
        
        // Enhanced audio configuration for better quality
        try config.audio.setBitrate(128_000)  // Increased from 96_000 to 128_000
        config.audio.setQuality(IVSBroadcastConfiguration.AudioQuality.high)  // Changed from medium to high
        logger.log("Audio config: 128kbps, high quality")
        
        return config
    }
}

extension IvsBroadcasterView: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: Error?
    ) {
        logger.log("Video recording finished - URL: \(outputFileURL.path)")
        
        if let error = error {
            logger.log("Video recording error: \(error)", level: .error)
        }
        
        var data = [String: Any]()
        data = [
            "isRecording": false,
            "videoPath": outputFileURL.path,
        ]
        if self._eventSink != nil {
            self._eventSink!(data)
        }
    }
}
 
