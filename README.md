# ivs_broadcaster

`ivs_broadcaster` is a Flutter package designed for broadcasting live video and playing streams using AWS Interactive Video Service (IVS). It supports broadcasting and playing video streams on both Android and iOS platforms.

## Table of Contents

- [Getting Started](#getting-started)
- [Setup](#setup)
  - [Android Setup](#android-setup)
  - [iOS Setup](#ios-setup)
- [Usage](#usage)
  - [Broadcaster](#broadcaster)
  - [Player](#player)
- [Methods for Broadcasting](#methods-for-broadcasting)
- [Methods for Player](#methods-for-player)
- [Listeners for Broadcasting](#listeners-for-broadcasting)
- [Listeners for Player](#listeners-for-player)
- [Additional Features](#additional-features)

## Getting Started

To use this package, you need an AWS account with an IVS channel set up. Follow the setup instructions for Android and iOS platforms.

## Setup

### Android Setup

1. Add the following permissions to your `AndroidManifest.xml` file:

    ```xml
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    ```

2. Initialize the broadcaster with your IVS channel URL and stream key:

    ```dart
    String imgset = 'rtmp://<your channel url>';
    String streamKey = '<your stream key>';
    ```

### iOS Setup

1. Add the following keys to your `Info.plist` file:

    ```plist
    <key>NSCameraUsageDescription</key>
    <string>To stream video</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>To stream the audio</string>
    ```

## Usage

### Broadcaster

To use the broadcaster, initialize it and add `BroadcaterPreview` to your widget tree:

```dart
import 'package:ivs_broadcaster/Broadcaster/ivs_broadcaster.dart';
import 'package:ivs_broadcaster/Broadcaster/Widgets/preview_widget.dart';

IvsBroadcaster? ivsBroadcaster;

@override
void initState() {
  super.initState();
  ivsBroadcaster = IvsBroadcaster.instance;
}

// In your widget tree
...
child: BroadcaterPreview(),
...
```

### Player

To use the player, initialize it and add `IvsPlayerView` to your widget tree:

```dart
import 'package:ivs_broadcaster/Player/ivs_player.dart';
import 'package:ivs_broadcaster/Player/ivs_player_view.dart';

IvsPlayer? ivsPlayer;

@override
void initState() {
  super.initState();
  ivsPlayer = IvsPlayer();
}

// In your widget tree
...
child: IvsPlayerView(
  controller: ivsPlayer!,
  autoDispose: true,
  aspectRatio: 16 / 9,
),
...
```

## Methods for Broadcasting

- **`Future<bool> requestPermissions();`**  
  Request camera and microphone permissions.

- **`Future<void> startPreview({required String imgset, required String streamKey, CameraType cameraType = CameraType.BACK, void Function(dynamic)? onData, void Function(dynamic)? onError});`**  
  Start the preview for broadcasting. Parameters include:
  - `imgset`: The URL of the IVS channel.
  - `streamKey`: The stream key for the broadcast.
  - `cameraType`: The camera type to use (e.g., BACK or FRONT).
  - `onData`: Callback for receiving data.
  - `onError`: Callback for error handling.

- **`Future<void> startBroadcast();`**  
  Start the live broadcast.

- **`Future<void> stopBroadcast();`**  
  Stop the live broadcast.

- **`Future<void> changeCamera(CameraType cameraType);`**  
  Change the camera being used for broadcasting.

- **`Future<void> zoomCamera(double scale);`**  
  Adjust the camera zoom level.

- **`Future<ZoomFactor> getZoomFactor();`**  
  Retrieve the minimum and maximum zoom levels.

- **`Future<void> updateCameraLens(IOSCameraLens lens);`**  
  Update the camera lens (e.g., UltraWide, Wide, etc.).

- **`Future<void> captureVideo({required int seconds});`**  
  Capture a local video for a specified duration.

- **`Future<void> setFocusMode(FocusMode mode);`**  
  Set the camera's focus mode.

- **`Future<void> setFocusPoint(Offset point);`**  
  Set the focus point on the screen.

## Methods for Player

- **`void startPlayer(String url, {required bool autoPlay, void Function(dynamic)? onData, void Function(dynamic)? onError});`**  
  Start the player with a specified URL and auto-play setting.

- **`void resume();`**  
  Resume playback.

- **`void pause();`**  
  Pause playback.

- **`void muteUnmute();`**  
  Toggle mute/unmute.

- **`void stopPlayer();`**  
  Stop the player.

- **`Future<List<String>> getQualities();`**  
  Get a list of available video qualities.

- **`Future<void> setQuality(String value);`**  
  Set the video quality.

- **`Future<void> toggleAutoQuality();`**  
  Toggle automatic quality adjustment.

- **`Future<bool> isAutoQuality();`**  
  Check if automatic quality adjustment is enabled.

- **`Future<void> seekTo(Duration duration);`**  
  Seek to a specific position in the video.

- **`Future<Duration> getPosition();`**  
  Get the current playback position.

## Listeners for Broadcasting

- **`Stream<BroadCastState> broadcastState;`**  
  Listen to the broadcast state (e.g., CONNECTED, CONNECTING).

- **`Stream<BroadCastQuality> broadcastQuality;`**  
  Listen to the broadcast quality.

- **`Stream<BroadCastHealth> broadcastHealth;`**  
  Listen to the network health during broadcasting.

- **`Stream<Offset> focusPoint;`**  
  Listen to the focus point updates.

- **`Stream<RetryState> retryState;`**  
  Listen to retry state changes during broadcasting.

## Listeners for Player

- **`StreamController<Duration> positionStream = StreamController.broadcast();`**  
  Stream for the current playback position.

- **`StreamController<Duration> syncTimeStream = StreamController.broadcast();`**  
  Stream for synchronization time.

- **`StreamController<Duration> durationStream = StreamController.broadcast();`**  
  Stream for the video duration.

- **`StreamController<String> qualityStream = StreamController.broadcast();`**  
  Stream for video quality changes.

- **`StreamController<PlayerState> playeStateStream = StreamController.broadcast();`**  
  Stream for player state changes.

- **`StreamController<String> errorStream = StreamController.broadcast();`**  
  Stream for error messages.

- **`StreamController<bool> isAutoQualityStream = StreamController.broadcast();`**  
  Stream for automatic quality adjustment status.

## Additional Features

- **Zoom Control:**  
  Use pinch gestures to zoom in and out during broadcasting.

- **Camera Switching:**  
  Switch between front and back cameras.

- **Focus Control:**  
  Set focus points and modes for better video quality.

- **Retry Mechanism:**  
  Automatically retry broadcasting in case of network issues.

- **Video Capture:**  
  Capture and save local videos during broadcasting.

- **Customizable UI:**  
  Modify the UI elements like buttons and overlays to fit your app's design.

## License

This project is licensed under the [MIT License](LICENSE).