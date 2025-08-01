// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:developer';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ivs_broadcaster/Broadcaster/Classes/camera_brightness.dart';
import 'package:ivs_broadcaster/Broadcaster/Classes/video_capturing_model.dart';
import 'package:ivs_broadcaster/Broadcaster/Widgets/preview_widget.dart';
import 'package:ivs_broadcaster/Broadcaster/ivs_broadcaster.dart';
import 'package:ivs_broadcaster/helpers/enums.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class HomePage extends StatefulWidget {
  final String channel;
  const HomePage({Key? key, required this.channel}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ValueNotifier<CameraBrightness> cameraBrightness = ValueNotifier(
      CameraBrightness(brightness: 0, minBrightness: 0, maxBrightness: 1));

  // Future<void> _zoomCamera(double scale) async {
  //   await ivsBroadcaster?.zoomCamera(scale);
  // }

  ValueNotifier<IOSCameraLens> currentCamera =
      ValueNotifier(IOSCameraLens.DefaultCamera);

  IvsBroadcaster? ivsBroadcaster;
  // String key = "sk_us-east-************************************";
  // String url = "rtmps:-***************************************";
  // String key = "sk_us-east-1_rDaEh55crJgC_JuCoeGBlcRIa1qnlkirfuwjSjuNKmy";
  // String url = "rtmps://7453a0e95db4.global-contribute.live-video.net:443/app/";
  late String key;
  late String url;

  double maxZoom = 4.0; // Maximum zoom level
  // final double _scale = 1.0;
  // final double _previousScale = 1.0;
  double minZoom = 1.0; // Minimum zoom level

  IvsQuality quality = IvsQuality.q1080;
  ValueNotifier<bool> showBox = ValueNotifier(false);
  Timer? timer;

  @override
  void dispose() {
    ivsBroadcaster?.stopBroadcast();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    super.dispose();
  }

  List<Map<String, dynamic>> channels = [
    {
      "key": "sk_us-east-1_u0AwAFbvFgns_RB85KQEnyoHTKc2Bc2eHIRQZYBMyes",
      "url": "rtmps://7453a0e95db4.global-contribute.live-video.net:443/app/",
    },
    {
      "key": "sk_us-east-1_RSL7QAIDuoWE_79iUJnsoDPLWBtg3n3FBDEfe4W1sAH",
      "url": "rtmps://7453a0e95db4.global-contribute.live-video.net:443/app/",
    },
    {
      "key": "sk_us-east-1_vLeJoSeVSWSK_Rp8caMzIUmB6j4Oa0Dd0Ldzde8otVi",
      "url": "rtmps://7453a0e95db4.global-contribute.live-video.net:443/app/",
    },
  ];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    key = channels[int.parse(widget.channel)]['key'];
    url = channels[int.parse(widget.channel)]['url'];
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    ivsBroadcaster = IvsBroadcaster.instance;
    ivsBroadcaster!.broadcastState.stream.listen((event) {
      log(event.name.toString(), name: "IVS Broadcaster");
      if (event == BroadCastState.CONNECTED) {
        ivsBroadcaster!.sendTimedData(
          "Connected to channel: ${key.substring(key.length - 10)}",
        );
      } else if (event == BroadCastState.DISCONNECTED) {
        ivsBroadcaster!.sendTimedData(
          "Disconnected from channel: ${key.substring(key.length - 10)}",
        );
      }
    });
    ivsBroadcaster!.broadcastQuality.stream.listen((event) {
      log(event.name.toString(), name: "IVS Broadcaster Quality");
    });
    ivsBroadcaster!.broadcastHealth.stream.listen((event) {
      log(event.name.toString(), name: "IVS Broadcaster Health");
    });
    ivsBroadcaster!.retryState.stream.listen((event) {
      log(event.name.toString(), name: "IVS Broadcaster Retry");
    });
    ivsBroadcaster!.focusPoint.stream.listen((event) {
      log("Focus Point: $event", name: "IVS Broadcaster Focus Point");
      showBox.value = true;
      startTimer();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      init();
    });
  }

  void startTimer() {
    timer?.cancel();
    timer = Timer(const Duration(seconds: 2), () {
      showBox.value = false;
    });
  }

  init() async {
    await Future.delayed(Durations.extralong4);
    await ivsBroadcaster!.startPreview(
      imgset: url,
      streamKey: key,
      quality: IvsQuality.auto,
      autoReconnect: true,
    );
    final zoomFactor = await ivsBroadcaster?.getZoomFactor();
    if (zoomFactor != null) {
      maxZoom = zoomFactor.maxZoom.toDouble();
      minZoom = zoomFactor.minZoom.toDouble();
    }
  }

  showSnackBar(BuildContext content, String message) {
    ScaffoldMessenger.of(content).showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  CameraType currentCameraType = CameraType.BACK;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Channel: ${key.substring(key.length - 10)}'),
        leading: IconButton(
          onPressed: () {
            Navigator.pop(context);
          },
          icon: CircleAvatar(
            backgroundColor: Colors.black.withOpacity(0.5),
            child: const Icon(
              Icons.arrow_back,
              color: Colors.white,
            ),
          ),
        ),
        actions: [
          IconButton(
            onPressed: () async {
              // await ivsBroadcaster
              //     ?.updateCameraLens(IOSCameraLens.UltraWideCamera);
              ivsBroadcaster!.sendTimedData(
                "Current Time: ${DateTime.now().toIso8601String()}",
              );
            },
            icon: const Icon(Icons.camera),
          ),
          IconButton(
            onPressed: () async {
              ivsBroadcaster?.setFocusMode(FocusMode.Auto);
              final cameraBrightness =
                  await ivsBroadcaster?.getCameraBrightness();
              if (cameraBrightness != null) {
                log("min: ${cameraBrightness.minBrightness}, max: ${cameraBrightness.maxBrightness}, current: ${cameraBrightness.brightness}");
                this.cameraBrightness.value = cameraBrightness;
              }
            },
            icon: const Icon(Icons.center_focus_strong),
          ),
          IconButton(
            onPressed: () {
              ivsBroadcaster?.toggleMute();
            },
            icon: const Icon(Icons.volume_off_rounded),
          ),
          IconButton(
            onPressed: () {
              currentCameraType = currentCameraType == CameraType.FRONT
                  ? CameraType.BACK
                  : CameraType.FRONT;
              ivsBroadcaster?.changeCamera(currentCameraType);
            },
            icon: const Icon(Icons.cameraswitch_rounded),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const Center(
            child: CircularProgressIndicator(),
          ),
          const BroadcaterPreview(),
          Positioned(
            height: 150,
            bottom: 0,
            left: 0,
            right: 0,
            child: StreamBuilder<BroadCastState>(
              stream: ivsBroadcaster?.broadcastState.stream,
              builder: (context, snapshot) {
                final isConnected = snapshot.data == BroadCastState.CONNECTED;
                final isConnecting = snapshot.data == BroadCastState.CONNECTING;
                return Container(
                  height: 150,
                  width: MediaQuery.of(context).size.width,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.3),
                  ),
                  padding: const EdgeInsets.all(15).copyWith(bottom: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Connection State: ${snapshot.data?.name.toString() ?? "No State"}",
                            ),
                            const SizedBox(
                              height: 10,
                            ),
                            FutureBuilder<List<IOSCameraLens>>(
                              future: ivsBroadcaster?.getAvailableCameraLens(),
                              builder: (context, snapshot) {
                                return ValueListenableBuilder(
                                  valueListenable: currentCamera,
                                  builder: (context, value, child) {
                                    if (snapshot.connectionState !=
                                        ConnectionState.done) {
                                      return const CupertinoActivityIndicator();
                                    }
                                    return DropdownMenu<IOSCameraLens>(
                                      dropdownMenuEntries: snapshot.data
                                              ?.map(
                                                (e) => DropdownMenuEntry(
                                                  value: e,
                                                  label: e.name,
                                                ),
                                              )
                                              .toList() ??
                                          [],
                                      initialSelection: value,
                                      inputDecorationTheme:
                                          const InputDecorationTheme(
                                        border: OutlineInputBorder(),
                                      ),
                                      onSelected: (selectedValue) async {
                                        if (selectedValue != null) {
                                          final data = await ivsBroadcaster
                                              ?.updateCameraLens(selectedValue);
                                          // Only update currentCamera if the configuration was successful
                                          if (data == "Configuration Updated") {
                                            currentCamera.value = selectedValue;
                                            showSnackBar(
                                              context,
                                              "Camera configuration updated",
                                            );
                                          } else {
                                            // Handle failure case here if necessary
                                            currentCamera.value =
                                                IOSCameraLens.DefaultCamera;
                                            showSnackBar(
                                              context,
                                              "Device does not support this camera configuration",
                                            );
                                          }
                                        }
                                      },
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        width: 10,
                      ),
                      InkWell(
                        onTap: () async {
                          await ivsBroadcaster?.captureVideo(
                            seconds: 10,
                          );
                        },
                        child: StreamBuilder<VideoCapturingModel>(
                          stream: ivsBroadcaster?.onVideoCapturingStream.stream,
                          builder: (context, snapshot) {
                            final isCapturing =
                                snapshot.data?.isRecording ?? false;
                            if (snapshot.data?.videoPath != null) {
                              print(snapshot.data?.videoPath);
                            }
                            return CircleAvatar(
                              radius: 35,
                              backgroundColor: isCapturing
                                  ? Colors.green
                                  : Colors.black.withOpacity(0.5),
                              child: isCapturing
                                  ? const Icon(
                                      Icons.stop_rounded,
                                      color: Colors.white,
                                    )
                                  : const Icon(
                                      Icons.fiber_manual_record_sharp,
                                      color: Colors.white,
                                    ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(
                        width: 10,
                      ),
                      InkWell(
                        onTap: () async {
                          if (isConnected) {
                            await ivsBroadcaster?.stopBroadcast();
                            return;
                          }
                          await ivsBroadcaster?.startBroadcast();
                        },
                        child: CircleAvatar(
                          radius: 35,
                          backgroundColor:
                              isConnected ? Colors.green : Colors.red,
                          child: isConnecting
                              ? const CupertinoActivityIndicator()
                              : isConnected
                                  ? const Icon(
                                      Icons.stop_rounded,
                                      color: Colors.white,
                                    )
                                  : const Icon(
                                      Icons.fiber_manual_record_sharp,
                                      color: Colors.white,
                                    ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: showBox,
            builder: (context, show, child) {
              return StreamBuilder<Offset>(
                stream: ivsBroadcaster?.focusPoint.stream,
                builder: (context, snapshot) {
                  final value = snapshot.data ?? const Offset(0, 0);
                  if (!show) return const SizedBox.shrink();
                  return Positioned(
                    top: value.dy - 80,
                    left: value.dx - 25,
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: Durations.short4,
                          height: 50,
                          width: 50,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.white.withOpacity(0.5),
                              width: 2,
                            ),
                          ),
                        ),
                        // Vertical Slider
                        RotatedBox(
                          quarterTurns: 3,
                          child: ValueListenableBuilder<CameraBrightness>(
                            valueListenable: cameraBrightness,
                            builder: (context, snapshot, child) {
                              return SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 2,
                                  overlayColor: Colors.transparent,
                                  thumbShape: SliderThumbIcon(
                                    iconData: Icons.wb_sunny_outlined,
                                    size: 30,
                                    color: Colors.yellow.withOpacity(0.8),
                                  ),
                                  trackShape:
                                      const RectangularSliderTrackShape(),
                                  activeTrackColor: Colors.yellow,
                                  inactiveTrackColor: Colors.yellow,
                                  thumbColor: Colors.transparent,
                                ),
                                child: Slider(
                                  onChangeEnd: (value) {
                                    startTimer();
                                  },
                                  value: (snapshot.brightness).toDouble(),
                                  min: snapshot.minBrightness.toDouble(),
                                  max: snapshot.maxBrightness.toDouble(),
                                  onChanged: (value) {
                                    startTimer();
                                    log("Brightness: $value");
                                    cameraBrightness.value = CameraBrightness(
                                      brightness: value.toInt(),
                                      minBrightness: snapshot.minBrightness,
                                      maxBrightness: snapshot.maxBrightness,
                                    );
                                    ivsBroadcaster?.setCameraBrightness(
                                      cameraBrightness.value,
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          StreamBuilder<RetryState>(
            stream: ivsBroadcaster?.retryState.stream,
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data != RetryState.NotRetrying) {
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                  ),
                  child: Center(
                    child: Text("RetryState: ${snapshot.data?.name}"),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }
}

class SliderThumbIcon extends SliderComponentShape {
  final IconData iconData;
  final double size;
  final Color color;

  SliderThumbIcon({
    required this.iconData,
    this.size = 24.0,
    this.color = Colors.blue,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size(size, size);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;

    final TextSpan span = TextSpan(
      text: String.fromCharCode(iconData.codePoint),
      style: TextStyle(
        fontSize: size,
        fontFamily: iconData.fontFamily,
        package: iconData.fontPackage,
        color: color,
      ),
    );

    final TextPainter tp = TextPainter(
      text: span,
      textAlign: TextAlign.center,
      textDirection: textDirection,
    );

    tp.layout();
    final Offset iconOffset = center - Offset(tp.width / 2, tp.height / 2);
    tp.paint(canvas, iconOffset);
  }
}
