import UIKit
import AVFoundation
import Flutter
import AmazonIVSPlayer

class IvsPlayerView: NSObject, FlutterPlatformView, FlutterStreamHandler, IVSPlayer.Delegate {
    
    private var playerView: UIView
    private var _methodChannel: FlutterMethodChannel?
    private var _eventChannel: FlutterEventChannel?
    private var _eventSink: FlutterEventSink?
    private var players: [String: IVSPlayer] = [:] // Dictionary to manage multiple players
    private var playerViews: [String: IVSPlayerView] = [:]
    private var playerId: String?
    
    // Constants for better code maintenance
    private enum PlayerConstants {
        static let syncThreshold: TimeInterval = 0.5 // Tolerance for sync in seconds
        static let defaultBufferSize: TimeInterval = 2.0 // Buffer size for livestreams in seconds
    }
    
    func view() -> UIView {
        return playerView
    }
    
    // MARK: - IVSPlayer Delegate Methods
    
    func player(_ player: IVSPlayer, didChangeState state: IVSPlayer.State) {
        guard let eventSink = _eventSink,
              let id = getPlayerIdFor(player: player) else { return }
        
        let dict: [String: Any] = [
            "playerId": id,
            "state": state.rawValue,
            "stateDescription": stateToString(state)
        ]
        eventSink(dict)
    }

    func player(_ player: IVSPlayer, didChangeDuration time: CMTime) {
        guard let eventSink = _eventSink,
              let id = getPlayerIdFor(player: player) else { return }
        
        let dict: [String: Any] = [
            "playerId": id,
            "duration": time.seconds
        ]
        eventSink(dict)
    }

    func player(_ player: IVSPlayer, didChangeSyncTime time: CMTime) {
        guard let eventSink = _eventSink,
              let id = getPlayerIdFor(player: player) else { return }
        
        let dict: [String: Any] = [
            "playerId": id,
            "syncTime": time.seconds
        ]
        eventSink(dict)
        
    }

    func player(_ player: IVSPlayer, didChangeQuality quality: IVSQuality?) {
        guard let eventSink = _eventSink,
              let id = getPlayerIdFor(player: player) else { return }
        
        let qualityInfo: [String: Any] = [
            "name": quality?.name ?? "",
            "bitrate": quality?.bitrate ?? 0,
            "codecs": quality?.codecs ?? ""
        ]
        
        let dict: [String: Any] = [
            "playerId": id,
            "quality": quality?.name ?? "",
            "qualityInfo": qualityInfo
        ]
        eventSink(dict)
    }
    
    func player(_ player: IVSPlayer, didOutputCue cue: IVSCue) {
        guard let eventSink = _eventSink,
              let id = getPlayerIdFor(player: player) else { return }
        
        if let textMetadataCue = cue as? IVSTextMetadataCue {
            let dict: [String: Any] = [
                "playerId": id,
                "type": "metadata",
                "metadata": textMetadataCue.text,
                "startTime": textMetadataCue.startTime.epoch,
                "endTime": textMetadataCue.endTime.epoch,
            ]
            eventSink(dict)
        }
    }

    func player(_ player: IVSPlayer, didFailWithError error: any Error) {
        print("PlayerError: \(error.localizedDescription)")
        guard let eventSink = _eventSink,
              let id = getPlayerIdFor(player: player) else { return }
        
        let dict: [String: Any] = [
            "playerId": id,
            "type": "error",
            "error": error.localizedDescription,
            "code": (error as NSError).code
        ]
        eventSink(dict)
        
        // Attempt to recover from error for this specific player only
        handlePlayerError(player: player, error: error, playerId: id)
    }

    func player(_ player: IVSPlayer, didSeekTo time: CMTime) {
        guard let eventSink = _eventSink,
              let id = getPlayerIdFor(player: player) else { return }
        
        let dict: [String: Any] = [
            "playerId": id,
            "seekedToTime": time.seconds
        ]
        eventSink(dict)
    }
    
    // MARK: - Flutter Stream Handler
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self._eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self._eventSink = nil
        disposeAllPlayer()
        return nil
    }
    
    // MARK: - Initialization
    
    init(_ frame: CGRect,
         viewId: Int64,
         args: Any?,
         messenger: FlutterBinaryMessenger
    ) {
        _methodChannel = FlutterMethodChannel(
            name: "ivs_player", binaryMessenger: messenger
        )
        _eventChannel = FlutterEventChannel(name: "ivs_player_event", binaryMessenger: messenger)
        playerView = UIView(frame: frame)
        super.init()
        _methodChannel?.setMethodCallHandler(onMethodCall)
        _eventChannel?.setStreamHandler(self)
         
    }
    
    // MARK: - Method Handler
    
    func onMethodCall(call: FlutterMethodCall, result: FlutterResult) {
        print("MethodCall: \(call.method)")
        switch(call.method) {
        case "createPlayer":
            guard let args = call.arguments as? [String: Any],
                  let playerId = args["playerId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments for createPlayer", details: nil))
                return
            }
            createPlayer(playerId: playerId)
            result(true)
            
        case "multiPlayer":
            guard let args = call.arguments as? [String: Any],
                  let urls = args["urls"] as? [String] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments for multiPlayer", details: nil))
                return
            }
            multiPlayer(urls)
            result("Players created successfully")
            
        case "selectPlayer":
            guard let args = call.arguments as? [String: Any],
                  let playerId = args["playerId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments for selectPlayer", details: nil))
                return
            }
            selectPlayer(playerId: playerId)
            result(true)
            
        case "startPlayer":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String,
                  let autoPlay = args["autoPlay"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments for startPlayer", details: nil))
                return
            }
            startPlayer(url: url, autoPlay: autoPlay)
            result(true)
            
        case "stopPlayer":
            if let playerId = self.playerId {
                stopPlayer(playerId: playerId)
            }
            result(true)
            
        case "dispose":
            disposeAllPlayer()
            result(true)
            
        case "mute":
            guard let playerId = self.playerId else {
                result(FlutterError(code: "NO_ACTIVE_PLAYER", message: "No active player", details: nil))
                return
            }
            mutePlayer(playerId: playerId)
            result(true)
            
        case "pause":
            guard let playerId = self.playerId else {
                result(FlutterError(code: "NO_ACTIVE_PLAYER", message: "No active player", details: nil))
                return
            }
            pausePlayer(playerId: playerId)
            result(true)
            
        case "resume":
            guard let playerId = self.playerId else {
                result(FlutterError(code: "NO_ACTIVE_PLAYER", message: "No active player", details: nil))
                return
            }
            resumePlayer(playerId: playerId)
            result(true)
            
        case "seek":
            guard let args = call.arguments as? [String: Any],
                  let playerId = self.playerId,
                  let time = args["time"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments for seek", details: nil))
                return
            }
            seekPlayer(playerId: playerId, time)
            result(true)
            
        case "position":
            if let playerId = self.playerId {
                result(getPosition(playerId: playerId))
            } else {
                result("0")
            }
            
        case "qualities":
            if let playerId = self.playerId {
                let qualities = getQualities(playerId: playerId)
                result(qualities)
            } else {
                result([])
            }
            
        case "setQuality":
            guard let args = call.arguments as? [String: Any],
                  let playerId = self.playerId,
                  let quality = args["quality"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments for setQuality", details: nil))
                return
            }
            setQuality(playerId: playerId, quality)
            result(true)
            
        case "autoQuality":
            guard let playerId = self.playerId else {
                result(FlutterError(code: "NO_ACTIVE_PLAYER", message: "No active player", details: nil))
                return
            }
            toggleAutoQuality(playerId: playerId)
            result(true)
            
        case "isAuto":
            guard let playerId = self.playerId else {
                result(false)
                return
            }
            result(isAuto(playerId: playerId))
            
        case "getScreenshot":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments for getScreenshot", details: nil))
                return
            }
            
            if let screenshot = getScreenShot(url: url) {
                result(screenshot)
            } else {
                result(nil)
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Player Management Methods
    
    // Unified player creation method with better configuration
    private func createPlayerInstance(playerId: String, setAsActive: Bool = false, autoPlay: Bool = false) -> IVSPlayer? {
        // Return existing player if already created
        if let existingPlayer = players[playerId] {
            return existingPlayer
        }
        
        let player = IVSPlayer()
        
        // Configure player for optimal livestream playback
        player.setLiveLowLatencyEnabled(true)
        
        // Store player and view
        players[playerId] = player
        playerViews[playerId] = IVSPlayerView()
        playerViews[playerId]?.player = player
        
        // Set delegate only for active player initially
        if setAsActive {
            player.delegate = self
            self.playerId = playerId
            player.volume = 1.0
        } else {
            player.volume = 0.0
        }
        
        // Load the stream
        if let url = URL(string: playerId) {
            player.load(url)
        }
        print("PlayerState: \(player.state)")
        // Auto play if requested
        if autoPlay {
            player.play()
        }
        
        print("Created player for: \(playerId), Active: \(setAsActive), AutoPlay: \(autoPlay)")
        return player
    }
    
    func createPlayer(playerId: String) {
        guard createPlayerInstance(playerId: playerId, setAsActive: false, autoPlay: true) != nil else {
            print("Failed to create player for: \(playerId)")
            return
        }
        
        // Mute all other players
//        muteAllPlayersExcept(activePlayerId: playerId)
        
//        // Attach view if this is the first/active player
//        if let playerView = playerViews[playerId] {
//            attachPreview(container: self.playerView, preview: playerView)
//        }
    }
    
    func multiPlayer(_ urls: [String]) {
        guard !urls.isEmpty else {
            print("multiPlayer called with empty URLs array")
            return
        }
        
        // Clear existing players if any
        disposeAllPlayer()
        
        // Set the first URL as the initial active player
        self.playerId = urls.first
        
        // Create all players
        for (index, url) in urls.enumerated() {
            let isActive = (index == 0)
            
            guard let player = createPlayerInstance(playerId: url, setAsActive: isActive, autoPlay: false) else {
                print("Failed to create player for URL: \(url)")
                continue
            }
            
            // Configure volume based on active state
            player.volume = isActive ? 1.0 : 0.0
        }
        
        // Start playing all players with the active one first
        if let firstPlayer = urls.first,
            let activePlayerView = playerViews[firstPlayer] {
            attachPreview(container: self.playerView, preview: activePlayerView)
          
            
            
            self.muteAllPlayersExcept(activePlayerId: firstPlayer)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                for (_, player) in self.players {
                    player.play()
                }
            }
        }
        
        print("MultiPlayer setup completed with \(urls.count) streams")
        print(getPlayerStatus())
    }
 
    
    func selectPlayer(playerId: String) {
        print("Selecting player: \(playerId)")
        
        // Create player if it doesn't exist
        var player: IVSPlayer?
        if players[playerId] == nil {
            print("Player \(playerId) not found, creating new player")
            player = createPlayerInstance(playerId: playerId, setAsActive: false, autoPlay: true)
        } else {
            player = players[playerId]
        }
        
        guard let selectedPlayer = player,
              let selectedPlayerView = playerViews[playerId] else {
            print("Failed to get or create player for: \(playerId)")
            return
        }
        
        // Store previous active player
        let previousPlayer = self.playerId
        
        // Update active player
        self.playerId = playerId
        
        // Update delegates - remove from previous, set to new
        if let previousId = previousPlayer, previousId != playerId {
            players[previousId]?.delegate = nil
        }
        selectedPlayer.delegate = self
        
        // Ensure the selected player is playing
        if selectedPlayer.state != .playing {
            selectedPlayer.play()
        }
        
        // Mute all players except the selected one
        muteAllPlayersExcept(activePlayerId: playerId)
        
        // Maintain all players to ensure they keep running
        maintainAllPlayers()
        
        // Smooth UI transition
        UIView.animate(withDuration: 0.2, animations: {
            self.playerView.alpha = 0
        }) { _ in
            // Update the preview
            self.attachPreview(container: self.playerView, preview: selectedPlayerView)
            
            // Fade in the new preview
            UIView.animate(withDuration: 0.3) {
                self.playerView.alpha = 1
            }
        }
        
        // Update events for the new active player
        updateEventsOfCurrentPlayer()
        
        print("Successfully selected player: \(playerId)")
        print(getPlayerStatus())
    }
    
    func updateEventsOfCurrentPlayer() {
        guard let playerId = self.playerId, let player = players[playerId] else {
            print("No active player to update events for")
            return
        }
        
        // Ensure delegate is set
        player.delegate = self
        
        // Send comprehensive state update
        let dict: [String: Any] = [
            "playerId": playerId,
            "state": player.state.rawValue,
            "stateDescription": stateToString(player.state),
            "syncTime": player.syncTime.seconds,
            "position": player.position.seconds,
            "quality": player.quality?.name ?? "",
            "autoQualityMode": player.autoQualityMode,
            "volume": player.volume,
            "isMuted": player.volume == 0
        ]
        _eventSink?(dict)
        
        print("Updated events for active player: \(playerId), state: \(stateToString(player.state))")
    }
    
    func startPlayer(url: String, autoPlay: Bool) {
        print("Starting player for URL: \(url), autoPlay: \(autoPlay)")
        
        // Check if player already exists
        if let existingPlayer = players[url], let existingPlayerView = playerViews[url] {
            print("Player already exists for URL: \(url)")
            self.playerId = url
            
            // Update delegate and ensure it's the active player
            existingPlayer.delegate = self
            
            if autoPlay && existingPlayer.state != .playing {
                existingPlayer.play()
            }
            
            // Mute all other players
            muteAllPlayersExcept(activePlayerId: url)
            
            // Attach the view
            attachPreview(container: self.playerView, preview: existingPlayerView)
            updateEventsOfCurrentPlayer()
            return
        }
        
        // Create new player if it doesn't exist
        guard let newPlayer = createPlayerInstance(playerId: url, setAsActive: true, autoPlay: autoPlay),
              let newPlayerView = playerViews[url] else {
            print("Failed to create player for URL: \(url)")
            return
        }
        
        // Mute all other players
        muteAllPlayersExcept(activePlayerId: url)
        
        // Attach the view
        attachPreview(container: self.playerView, preview: newPlayerView)
        
        print("Successfully started player for URL: \(url)")
    }
    
    func stopPlayer(playerId: String) {
        print("Stopping player: \(playerId)")
        
        guard let player = players[playerId] else {
            print("Player \(playerId) not found")
            return
        }
        
        // Properly cleanup resources
        player.pause()
        player.delegate = nil
        
        // Remove the player and view
        players.removeValue(forKey: playerId)
        playerViews.removeValue(forKey: playerId)
        
        print("Player \(playerId) stopped and removed")
        
        // Update active player if the stopped player was active
        if playerId == self.playerId {
            print("Stopped player was active, selecting new active player")
            
            // Find the next available player to make active
            if let newActiveId = players.keys.first,
               let newActivePlayer = players[newActiveId],
               let newActivePlayerView = playerViews[newActiveId] {
                
                // Set as new active player
                self.playerId = newActiveId
                newActivePlayer.delegate = self
                
                // Ensure it's playing and unmuted
                if newActivePlayer.state != .playing {
                    newActivePlayer.play()
                }
                muteAllPlayersExcept(activePlayerId: newActiveId)
                
                // Update UI
                attachPreview(container: self.playerView, preview: newActivePlayerView)
                updateEventsOfCurrentPlayer()
                
                print("New active player set: \(newActiveId)")
            } else {
                // No players left, clear everything
                self.playerId = nil
                DispatchQueue.main.async {
                    self.playerView.subviews.forEach { $0.removeFromSuperview() }
                }
                print("No players remaining, UI cleared")
            }
        }
    }
    
    func disposeAllPlayer() {
        print("Disposing all players...")
        
        // Safely dispose of all players
        let playerIds = Array(players.keys)
        for playerId in playerIds {
            if let player = players[playerId] {
                // Stop and clean up the player
                player.pause()
                player.delegate = nil
                
                // Remove from dictionaries
                players.removeValue(forKey: playerId)
                playerViews.removeValue(forKey: playerId)
                
                print("Disposed player: \(playerId)")
            }
        }
        
        // Clear active player reference
        playerId = nil
        
        // Clear the UI
        DispatchQueue.main.async {
            self.playerView.subviews.forEach { $0.removeFromSuperview() }
        }
        
        print("All players disposed successfully")
    }
    
    // MARK: - Player Control Methods
    
    func mutePlayer(playerId: String) {
        guard let player = players[playerId] else {
            print("Player \(playerId) not found for mute operation")
            return
        }
        
        let wasMuted = (player.volume == 0)
        
        if playerId == self.playerId {
            // For active player, toggle mute state
            player.volume = wasMuted ? 1.0 : 0.0
            
            // Report volume change
            let dict: [String: Any] = [
                "playerId": playerId, 
                "type": "volume", 
                "isMuted": !wasMuted,
                "volume": player.volume
            ]
            _eventSink?(dict)
            
            print("Active player \(playerId) \(wasMuted ? "unmuted" : "muted")")
        } else {
            // For inactive players, they should remain muted
            player.volume = 0.0
            print("Inactive player \(playerId) kept muted")
        }
    }
    
    func pausePlayer(playerId: String) {
        guard let player = players[playerId] else { return }
        player.pause()
    }
    
    func resumePlayer(playerId: String) {
        guard let player = players[playerId] else { return }
        player.play()
    }
    
    func seekPlayer(playerId: String, _ timeString: String) {
        guard let player = players[playerId],
              let timeValue = Double(timeString) else { return }
        
        player.seek(to: CMTimeMakeWithSeconds(timeValue, preferredTimescale: 1000))
    }
    
    func getPosition(playerId: String) -> String {
        guard let player = players[playerId] else { return "0" }
        return String(format: "%.3f", player.position.seconds)
    }
    
    func getQualities(playerId: String) -> [[String: Any]] {
        guard let player = players[playerId] else { return [] }
        
        // Return detailed quality information
        return player.qualities.map { quality in
            return [
                "name": quality.name,
                "bitrate": quality.bitrate,
                "codecs": quality.codecs
            ]
        }
    }
    
    func setQuality(playerId: String, _ quality: String) {
        guard let player = players[playerId] else { return }
        let qualities = player.qualities
        let qualityToChange = qualities.first { $0.name == quality }
        
        if let qualityToSet = qualityToChange {
            player.setQuality(qualityToSet, adaptive: false)
            _eventSink?(["playerId": playerId, "type": "qualityChanged", "quality": quality])
        }
    }
    
    func toggleAutoQuality(playerId: String) {
        guard let player = players[playerId] else { return }
        player.autoQualityMode.toggle()
        _eventSink?(["playerId": playerId, "type": "autoQuality", "enabled": player.autoQualityMode])
    }
    
    func isAuto(playerId: String) -> Bool {
        guard let player = players[playerId] else { return false }
        return player.autoQualityMode
    }
    
    // MARK: - Screenshot Method
    
    func getScreenShot(url: String) -> [UInt8]? {
        guard let videoURL = URL(string: url) else {
            print("Invalid URL for screenshot")
            return nil
        }
        
        // Create an AVAsset and AVAssetImageGenerator
        let asset = AVAsset(url: videoURL) // Fixed: Use the provided URL instead of hardcoded one
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Define the time for the screenshot (1 second mark)
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        
        do {
            // Generate the CGImage
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            // Convert to UIImage
            let image = UIImage(cgImage: cgImage)
            guard let imageData = image.pngData() else { return nil }
            return [UInt8](imageData)
        } catch {
            print("Failed to generate screenshot: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Helper Methods
    
    // Centralized method to mute all players except the active one
    private func muteAllPlayersExcept(activePlayerId: String) {
        for (playerId, player) in players {
            player.volume = (playerId == activePlayerId) ? 1.0 : 0.0
        }
        print("Muted all players except: \(activePlayerId)")
    }
    
    // Method to get current player status for debugging
    private func getPlayerStatus() -> String {
        var status = "=== Player Status ===\n"
        status += "Active Player: \(playerId ?? "None")\n"
        status += "Total Players: \(players.count)\n"
        
        for (playerId, player) in players {
            let isActive = (playerId == self.playerId) ? "🔴" : "⚪"
            let volume = player.volume == 1.0 ? "🔊" : "🔇"
            status += "\(isActive) \(playerId): \(stateToString(player.state)) \(volume)\n"
        }
        
        return status
    }
    
    // Method to ensure all players are properly maintained
    private func maintainAllPlayers() {
        DispatchQueue.main.async {
            for (playerId, player) in self.players {
                // Ensure inactive players are still playing but muted
                if playerId != self.playerId {
                    // Reload if player has stopped or encountered an error
                    if player.state == .idle || player.state == .ended {
                        if let url = player.path {
                            print("Reloading stopped player: \(playerId)")
                            player.load(url)
                        }
                    }
                    
                    // Ensure player is playing if it's ready
                    if player.state == .ready || player.state == .buffering {
                        player.play()
                    }
                    
                    // Ensure it's muted
                    player.volume = 0.0
                } else {
                    // Ensure active player has proper volume and is playing
                    player.volume = 1.0
                    if player.state == .ready && player.state != .playing {
                        player.play()
                    }
                }
            }
        }
    }
    
    private func attachPreview(container: UIView, preview: UIView) {
        // Clear current view, and then attach the new view
        container.subviews.forEach { $0.removeFromSuperview() }
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }
    
    private func getPlayerIdFor(player: IVSPlayer) -> String? {
        return players.first(where: { $0.value === player })?.key
    }
    
    private func handlePlayerError(player: IVSPlayer, error: Error, playerId: String) {
        let nsError = error as NSError
        
        print("Player \(playerId) encountered error: \(error.localizedDescription) (Code: \(nsError.code))")
        
        // Attempt to recover based on error type for this specific player
        if nsError.domain == NSURLErrorDomain || nsError.code == -1009 { // Network errors
            print("Network error detected for player \(playerId), attempting recovery...")
            
            // Wait briefly and try to reload only this player
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if let url = player.path {
                    print("Reloading player \(playerId) after network error")
                    player.load(url)
                    
                    // Only play if this player should be playing
                    if self.players[playerId] != nil {
                        // Small delay before playing to ensure load completes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            player.play()
                            
                            // Restore proper volume state
                            if playerId == self.playerId {
                                player.volume = 1.0
                            } else {
                                player.volume = 0.0
                            }
                        }
                    }
                }
            }
        } else {
            // For other types of errors, log and continue
            print("Non-recoverable error for player \(playerId): \(error.localizedDescription)")
        }
    }
    
    private func stateToString(_ state: IVSPlayer.State) -> String {
        switch state {
        case .idle: return "idle"
        case .ready: return "ready"
        case .buffering: return "buffering"
        case .playing: return "playing"
        case .ended: return "ended"
        @unknown default: return "unknown"
        }
    }
}
