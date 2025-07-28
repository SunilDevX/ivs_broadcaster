package com.example.ivs_broadcaster;


import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Matrix;
import android.graphics.Point;
import android.graphics.Rect;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CameraMetadata;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.MeteringRectangle;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.Size;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.widget.LinearLayout;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;

import com.amazonaws.ivs.broadcast.AudioDevice;
import com.amazonaws.ivs.broadcast.BroadcastConfiguration;
import com.amazonaws.ivs.broadcast.BroadcastException;
import com.amazonaws.ivs.broadcast.BroadcastSession;
import com.amazonaws.ivs.broadcast.Device;
import com.amazonaws.ivs.broadcast.ImageDevice;
import com.amazonaws.ivs.broadcast.ImagePreviewView;
import com.amazonaws.ivs.broadcast.Presets;
import com.amazonaws.ivs.broadcast.SurfaceSource;
import com.amazonaws.ivs.broadcast.TransmissionStats;
import com.google.gson.Gson;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.platform.PlatformView;

public class StreamView implements PlatformView, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private static final String TAG = "StreamView";
    private final LinearLayout layout;
    private EventChannel.EventSink eventSink;
    private BroadcastSession broadcastSession;
    private AudioDevice audioDevice;
    private final Context context;
    private final Handler mainHandler;
    private CameraDevice cameraDevice;
    private CameraCaptureSession captureSession;
    private CaptureRequest.Builder captureRequestBuilder;
    private String defaultCameraType = "0"; // Default to rear camera

    private boolean isMuted = false;

    StreamView(Context context, BinaryMessenger messenger) {
        this.context = context;
        layout = new LinearLayout(context);
        mainHandler = new Handler(Looper.getMainLooper());

        MethodChannel methodChannel = new MethodChannel(messenger, "ivs_broadcaster");
        EventChannel eventChannel = new EventChannel(messenger, "ivs_broadcaster_event");

        methodChannel.setMethodCallHandler(this);
        eventChannel.setStreamHandler(this);
        layout.setOnTouchListener((v, event) -> {
            if (event.getAction() == MotionEvent.ACTION_DOWN) {
                setFocusPoint(event, layout);
            }
            return true;
        });
    }

    @Override
    public View getView() {
        return layout;
    }

    @Override
    public void dispose() {
        stopBroadcast();
        releaseCamera();
    }

    // --- Method Names and Argument Keys ---
    private static final String METHOD_START_PREVIEW = "startPreview";
    private static final String METHOD_START_BROADCAST = "startBroadcast";
    private static final String METHOD_GET_CAMERA_ZOOM_FACTOR = "getCameraZoomFactor";
    private static final String METHOD_ZOOM_CAMERA = "zoomCamera";
    private static final String METHOD_UPDATE_CAMERA_LENS = "updateCameraLens";
    private static final String METHOD_MUTE = "mute";
    private static final String METHOD_IS_MUTED = "isMuted";
    private static final String METHOD_CHANGE_CAMERA = "changeCamera";
    private static final String METHOD_GET_AVAILABLE_CAMERA_LENS = "getAvailableCameraLens";
    private static final String METHOD_STOP_BROADCAST = "stopBroadcast";
    private static final String METHOD_SET_FOCUS_MODE = "setFocusMode";
    private static final String METHOD_CAPTURE_VIDEO = "captureVideo";
    private static final String METHOD_STOP_VIDEO_CAPTURE = "stopVideoCapture";
    private static final String METHOD_SEND_TIME_METADATA = "sendTimeMetaData";

    private static final String ARG_IMGSET = "imgset";
    private static final String ARG_STREAM_KEY = "streamKey";
    private static final String ARG_QUALITY = "quality";
    private static final String ARG_AUTO_RECONNECT = "autoReconnect";
    private static final String ARG_ZOOM = "zoom";
    private static final String ARG_LENS = "lens";
    private static final String ARG_TYPE = "type";
    private static final String ARG_SECONDS = "seconds";


    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case METHOD_START_PREVIEW:
                startPreview(call.argument(ARG_IMGSET), call.argument(ARG_STREAM_KEY), call.argument(ARG_QUALITY), call.argument(ARG_AUTO_RECONNECT));
                result.success(true);
                break;
            case METHOD_START_BROADCAST:
                startBroadcast();
                result.success("Broadcasting Started");
                break;
            case METHOD_STOP_BROADCAST:
                stopBroadcast();
                result.success("Broadcast Stopped");
                break;
            case METHOD_MUTE:
                toggleMute();
                result.success(isMuted ? "Muted" : "Unmuted");
                break;
            case METHOD_IS_MUTED:
                result.success(isMuted);
                break;
            case METHOD_SEND_TIME_METADATA:
//                sendMetaData(call.argument("metadata"));
                result.success(true);
                break;
            case METHOD_GET_CAMERA_ZOOM_FACTOR:
                result.success(getCameraZoomFactor());
                break;
            case METHOD_ZOOM_CAMERA:
                zoomCamera(call.argument(ARG_ZOOM));
                result.success(true);
                break;
            case METHOD_CHANGE_CAMERA:
                changeCamera(call.argument(ARG_TYPE));
                result.success("Camera Changed");
                break;
            case METHOD_SET_FOCUS_MODE:
                setFocusMode(call.argument(ARG_TYPE));
                result.success(true);
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    // --- Camera Control Methods ---
    private void setFocusPoint(MotionEvent event, View previewView) {
        if (cameraDevice == null || captureRequestBuilder == null) {
            Log.e(TAG, "No Camera Device Available");
            return;
        }

        Integer currentFocusMode = captureRequestBuilder.get(CaptureRequest.CONTROL_AF_MODE);
        if (currentFocusMode != null && currentFocusMode == CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE) {
            Log.d(TAG, "Camera is on Continuous Auto Focus. Set it to Auto Focus first.");
            return;
        }

        try {
            CameraManager manager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
            CameraCharacteristics characteristics = manager.getCameraCharacteristics(cameraDevice.getId());
            Rect sensorArraySize = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
            if (sensorArraySize == null) return;

            // Convert touch coordinates to sensor coordinates.
            final int y = (int) ((event.getX() / (float) previewView.getWidth()) * (float) sensorArraySize.height());
            final int x = (int) ((event.getY() / (float) previewView.getHeight()) * (float) sensorArraySize.width());
            final int halfTouchWidth = 150;
            final int halfTouchHeight = 150;
            MeteringRectangle focusArea = new MeteringRectangle(Math.max(x - halfTouchWidth, 0),
                    Math.max(y - halfTouchHeight, 0),
                    halfTouchWidth * 2,
                    halfTouchHeight * 2,
                    MeteringRectangle.METERING_WEIGHT_MAX - 1);

            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_REGIONS, new MeteringRectangle[]{focusArea});
            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO);
            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_START);
            captureSession.setRepeatingRequest(captureRequestBuilder.build(), null, mainHandler);

            Map<Object, Object> data = new HashMap<>();
            data.put("focusPoint", (event.getX() + "_" + event.getY()));
            sendEvent(data);
            Log.d(TAG, "Focus point set at: " + event.getX() + ", " + event.getY());
        } catch (CameraAccessException e) {
            Log.e(TAG, "Error setting focus point", e);
        }
    }

    private boolean setFocusMode(String type) {
        if (cameraDevice == null || captureRequestBuilder == null) return false;

        int focusMode;
        switch (type) {
            case "0":
                focusMode = CaptureRequest.CONTROL_AF_MODE_OFF;
                break;
            case "1":
                focusMode = CaptureRequest.CONTROL_AF_MODE_AUTO;
                break;
            case "2":
                focusMode = CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE;
                break;
            default:
                Log.e(TAG, "Invalid focus mode type");
                return false;
        }

        try {
            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, focusMode);
            captureSession.setRepeatingRequest(captureRequestBuilder.build(), null, mainHandler);
            return true;
        } catch (CameraAccessException e) {
            Log.e(TAG, "Error setting focus mode", e);
            return false;
        }
    }

    private void zoomCamera(Double zoomLevel) {
        if (cameraDevice == null) return;
        try {
            CameraManager cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
            CameraCharacteristics characteristics = cameraManager.getCameraCharacteristics(cameraDevice.getId());
            Rect sensorArraySize = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
            Float maxZoom = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM);

            if (maxZoom == null || sensorArraySize == null) return;

            if (zoomLevel < 1.0f) zoomLevel = 1.0;
            if (zoomLevel > maxZoom) zoomLevel = (double) maxZoom;

            int cropWidth = (int) (sensorArraySize.width() / zoomLevel);
            int cropHeight = (int) (sensorArraySize.height() / zoomLevel);
            int left = (sensorArraySize.width() - cropWidth) / 2;
            int top = (sensorArraySize.height() - cropHeight) / 2;

            Rect zoomRect = new Rect(left, top, left + cropWidth, top + cropHeight);
            captureRequestBuilder.set(CaptureRequest.SCALER_CROP_REGION, zoomRect);
            captureSession.setRepeatingRequest(captureRequestBuilder.build(), null, mainHandler);

        } catch (CameraAccessException e) {
            Log.e(TAG, "Error applying zoom", e);
        }
    }

    private Map<String, Object> getCameraZoomFactor() {
        Map<String, Object> zoomData = new HashMap<>();
        try {
            CameraManager cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
            if (cameraManager != null) {
                CameraCharacteristics characteristics = cameraManager.getCameraCharacteristics(defaultCameraType);
                Float maxZoom = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM);
                zoomData.put("minZoom", 1.0f);
                zoomData.put("maxZoom", maxZoom != null ? maxZoom : 1.0f);
            }
        } catch (CameraAccessException e) {
            Log.e(TAG, "Error getting zoom factor", e);
        }
        return zoomData;
    }

    // --- Broadcast Session Management ---
    private String streamUrl;
    private String streamKey;
    private String quality;
    private Boolean autoReconnect;
    private SurfaceSource source;
    private Device.Descriptor currentCamera;

    private void startPreview(String url, String key, String quality, Boolean autoReconnect) {
        this.streamUrl = url;
        this.streamKey = key;
        this.autoReconnect = autoReconnect;
        this.quality = quality;

        BroadcastConfiguration config = getConfig(quality);
        config.mixer.slots =  new BroadcastConfiguration.Mixer.Slot[] {
                BroadcastConfiguration.Mixer.Slot.with(slot -> {
                    // Bind to user image if unbound
                    slot.setPreferredVideoInput(
                            Device.Descriptor.DeviceType.USER_IMAGE);
                    slot.setName("custom");
                    return slot;
                }),
        };
        config.autoReconnect.setEnabled(autoReconnect);
        broadcastSession = new BroadcastSession(context, broadcastListener, config, Presets.Devices.MICROPHONE(context));
        for (Device device : broadcastSession.listAttachedDevices()) {
            if (device.getDescriptor().type == Device.Descriptor.DeviceType.MICROPHONE) {
                audioDevice = (AudioDevice) device;
            }
        }
        for(Device.Descriptor desc: BroadcastSession.listAvailableDevices(context)) {
            if(desc.type == Device.Descriptor.DeviceType.CAMERA &&
                    desc.position == Device.Descriptor.Position.BACK) {
                broadcastSession.attachDevice(desc, device -> {
                    LinearLayout previewHolder =  layout;
                    currentCamera =  device.getDescriptor();
                    ImagePreviewView preview = ((ImageDevice)device).getPreviewView(BroadcastConfiguration.AspectMode.FILL);
                    preview.setLayoutParams(new LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.MATCH_PARENT,
                            LinearLayout.LayoutParams.MATCH_PARENT));
                    previewHolder.addView(preview);
                    // Bind the camera to the mixer slot we created above.
                    broadcastSession.getMixer().bind(device, "custom");
                });
                break;
            }
        }
//        ImagePreviewView preview = broadcastSession.getPreviewView(BroadcastConfiguration.AspectMode.FILL);
//        preview.setLayoutParams(new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT));
//        layout.addView(preview);
//
//        // **FIX:** Wait for the preview view to be laid out before starting the camera.
//        // This ensures we have valid dimensions to choose the correct preview size.
//        preview.addOnLayoutChangeListener((v, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom) -> {
//            if (v.getWidth() > 0 && v.getHeight() > 0) {
//                v.removeOnLayoutChangeListener( (View.OnLayoutChangeListener) v.getTag());
//                startCamera2(ivsSurface, v.getWidth(), v.getHeight());
//            }
//        });
    }


    // **FIX:** Updated to accept view dimensions and use chooseOptimalSize
    private void startCamera2(Surface ivsSurface, int viewWidth, int viewHeight) {
        CameraManager manager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
        try {
            if (ActivityCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions((Activity) context, new String[]{Manifest.permission.CAMERA}, 100);
                return;
            }

            CameraCharacteristics characteristics = manager.getCameraCharacteristics(defaultCameraType);
            StreamConfigurationMap map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            if (map == null) {
                Log.e(TAG, "Cannot get stream configuration map.");
                return;
            }

            // **FIX:** Robustly choose the best preview size instead of just the first one.
            Size previewSize = chooseOptimalSize(map.getOutputSizes(SurfaceTexture.class), viewWidth, viewHeight);
            Log.i(TAG, "Selected Preview Size: " + previewSize.getWidth() + "x" + previewSize.getHeight());

            manager.openCamera(defaultCameraType, new CameraDevice.StateCallback() {
                @Override
                public void onOpened(@NonNull CameraDevice camera) {
                    cameraDevice = camera;
                    createCaptureSession(ivsSurface);
                }

                @Override
                public void onDisconnected(@NonNull CameraDevice camera) {
                    camera.close();
                    cameraDevice = null;
                }

                @Override
                public void onError(@NonNull CameraDevice camera, int error) {
                    camera.close();
                    cameraDevice = null;
                    Log.e(TAG, "Camera error: " + error);
                }
            }, mainHandler);

        } catch (CameraAccessException e) {
            Log.e(TAG, "Camera access exception: ", e);
        }
    }

    private void createCaptureSession(Surface ivsSurface) {
        try {
            if (cameraDevice == null) {
                Log.e(TAG, "cameraDevice is null, cannot create capture session.");
                return;
            }
            captureRequestBuilder = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            captureRequestBuilder.addTarget(ivsSurface);
            cameraDevice.createCaptureSession(Collections.singletonList(ivsSurface), new CameraCaptureSession.StateCallback() {
                @Override
                public void onConfigured(@NonNull CameraCaptureSession session) {
                    captureSession = session;
                    try {
                        captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
                        session.setRepeatingRequest(captureRequestBuilder.build(), null, mainHandler);
                    } catch (CameraAccessException e) {
                        Log.e(TAG, "Failed to start camera preview.", e);
                    }
                }

                @Override
                public void onConfigureFailed(@NonNull CameraCaptureSession session) {
                    Log.e(TAG, "CaptureSession Configuration Failed");
                }
            }, mainHandler);
        } catch (CameraAccessException e) {
            Log.e(TAG, "createCaptureSession CameraAccessException", e);
        }
    }

    private void startBroadcast() {
        if (broadcastSession != null && broadcastSession.isReady()) {
            broadcastSession.start(streamUrl, streamKey);
        } else {
            Log.w(TAG, "Broadcast session not ready, cannot start.");
        }
    }

    private void stopBroadcast() {
        if (broadcastSession != null) {
            broadcastSession.stop();
            broadcastSession.release();
            broadcastSession = null;
            Map<Object, Object> event = new HashMap<>();
            event.put("state", "DISCONNECTED");
            sendEvent(event);
            layout.removeAllViews();
        }
        releaseCamera();
    }

    private void toggleMute() {
        if (audioDevice != null) {
            isMuted = !isMuted;
            audioDevice.setGain(isMuted ? 0.0f : 1.0f);
        }
    }

    private void changeCamera(String type) {
        Device.Descriptor.Position position = type.equals("0")? Device.Descriptor.Position.FRONT: Device.Descriptor.Position.BACK;
        for(Device.Descriptor device: BroadcastSession.listAvailableDevices(context)) {
            if(device.type == Device.Descriptor.DeviceType.CAMERA &&
                    device.position == position) {
                setImagePreviewView(null);
                broadcastSession.exchangeDevices(currentCamera, device, camera -> {
                    // Set the preview view for the new device.
                    setImagePreviewView(((ImageDevice)camera).getPreviewView(BroadcastConfiguration.AspectMode.FILL));
                    currentCamera = camera.getDescriptor();
                });
                break;
            }
        }
//        if (broadcastSession == null || cameraDevice == null) return;
//        CameraManager manager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
//        try {
//            String newCameraId = null;
//            for (String cameraId : manager.getCameraIdList()) {
//                CameraCharacteristics characteristics = manager.getCameraCharacteristics(cameraId);
//                Integer lensFacing = characteristics.get(CameraCharacteristics.LENS_FACING);
//                if (lensFacing == null) continue;
//
//                if (type.equals("0") && lensFacing == CameraCharacteristics.LENS_FACING_FRONT) {
//                    newCameraId = cameraId;
//                    break;
//                }
//                if (type.equals("1") && lensFacing == CameraCharacteristics.LENS_FACING_BACK) {
//                    newCameraId = cameraId;
//                    break;
//                }
//            }
//
//            if (newCameraId != null && !newCameraId.equals(defaultCameraType)) {
//                releaseCamera();
//                defaultCameraType = newCameraId;
//                startCamera2(source.getInputSurface(), layout.getWidth(), layout.getHeight());
//            }
//        } catch (CameraAccessException e) {
//            Log.e(TAG, "Failed to change camera.", e);
//        }
    }

    private void setImagePreviewView(ImagePreviewView preview) {
        if (preview == null){
            layout.removeAllViews();
            return;
        }
        layout.removeAllViews();
        preview.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.MATCH_PARENT));
        layout.addView(preview);
    }

    // **FIX:** Added helper method to choose optimal preview size
    private Size chooseOptimalSize(Size[] choices, int viewWidth, int viewHeight) {
        List<Size> bigEnough = new ArrayList<>();
        List<Size> notBigEnough = new ArrayList<>();

        // Ensure view dimensions are not zero
        int w = viewWidth > 0 ? viewWidth : 1920; // Default to a common size if view not laid out
        int h = viewHeight > 0 ? viewHeight : 1080;

        for (Size option : choices) {
            // Match aspect ratio and size
            if (option.getWidth() == w && option.getHeight() == h) {
                return option; // Perfect match
            }
            if (option.getHeight() == option.getWidth() * h / w) {
                if (option.getWidth() >= w && option.getHeight() >= h) {
                    bigEnough.add(option);
                } else {
                    notBigEnough.add(option);
                }
            }
        }

        if (!bigEnough.isEmpty()) {
            return Collections.min(bigEnough, new CompareSizesByArea());
        } else if (!notBigEnough.isEmpty()) {
            return Collections.max(notBigEnough, new CompareSizesByArea());
        } else {
            Log.w(TAG, "Couldn't find any suitable preview size, picking first available.");
            return choices[0];
        }
    }

    // **FIX:** Added comparator for size selection
    static class CompareSizesByArea implements Comparator<Size> {
        @Override
        public int compare(Size lhs, Size rhs) {
            return Long.signum((long) lhs.getWidth() * lhs.getHeight() - (long) rhs.getWidth() * rhs.getHeight());
        }
    }


    private BroadcastConfiguration getConfig(String quality) {
        BroadcastConfiguration config = Presets.Configuration.STANDARD_PORTRAIT;
        switch (quality) {
            case "360":
                config.video.setSize(640, 360);
                config.video.setInitialBitrate(800000);
                break;
            case "720":
                config.video.setSize(1280, 720);
                config.video.setInitialBitrate(2500000);
                break;
            case "1080":
            default:
                config.video.setSize(1920, 1080);
                config.video.setInitialBitrate(5000000);
                break;
        }
        return config;
    }

    private final BroadcastSession.Listener broadcastListener = new BroadcastSession.Listener() {
        @Override
        public void onStateChanged(@NonNull BroadcastSession.State state) {
            Map<Object, Object> event = new HashMap<>();
            event.put("state", state.name().toUpperCase());
            sendEvent(event);
        }

        @Override
        public void onError(@NonNull BroadcastException exception) {
            Map<Object, Object> event = new HashMap<>();
            event.put("error", exception.getError().name() + ": " + exception.getDetail());
            sendEvent(event);
        }

        // Other listener methods...
    };

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        this.eventSink = events;
    }

    @Override
    public void onCancel(Object arguments) {
        this.eventSink = null;
    }

    private void sendEvent(Map<Object, Object> event) {
        if (eventSink != null) {
            Log.d(TAG, "Sending Event: " + event.toString());
            mainHandler.post(() -> eventSink.success(new Gson().toJson(event)));
        }
    }

    private void releaseCamera() {
        if (captureSession != null) {
            captureSession.close();
            captureSession = null;
        }
        if (cameraDevice != null) {
            cameraDevice.close();
            cameraDevice = null;
        }
        captureRequestBuilder = null;
    }
}

//package com.example.ivs_broadcaster;
//
//
//import android.Manifest;
//import android.app.Activity;
//import android.content.Context;
//import android.content.pm.PackageManager;
//import android.graphics.Matrix;
//import android.graphics.Point;
//import android.graphics.Rect;
//import android.graphics.SurfaceTexture;
//import android.hardware.camera2.CameraAccessException;
//import android.hardware.camera2.CameraCaptureSession;
//import android.hardware.camera2.CameraCharacteristics;
//import android.hardware.camera2.CameraDevice;
//import android.hardware.camera2.CameraManager;
//import android.hardware.camera2.CameraMetadata;
//import android.hardware.camera2.CaptureRequest;
//import android.hardware.camera2.params.MeteringRectangle;
//import android.hardware.camera2.params.StreamConfigurationMap;
//import android.os.Build;
//import android.os.Handler;
//import android.os.Looper;
//import android.util.Log;
//import android.util.Size;
//import android.view.MotionEvent;
//import android.view.Surface;
//import android.view.TextureView;
//import android.view.View;
//import android.widget.LinearLayout;
//
//import androidx.annotation.NonNull;
//import androidx.core.app.ActivityCompat;
//
//import com.amazonaws.ivs.broadcast.AudioDevice;
//import com.amazonaws.ivs.broadcast.BroadcastConfiguration;
//import com.amazonaws.ivs.broadcast.BroadcastException;
//import com.amazonaws.ivs.broadcast.BroadcastSession;
//import com.amazonaws.ivs.broadcast.Device;
//import com.amazonaws.ivs.broadcast.ImagePreviewView;
//import com.amazonaws.ivs.broadcast.Presets;
//import com.amazonaws.ivs.broadcast.SurfaceSource;
//import com.amazonaws.ivs.broadcast.TransmissionStats;
//import com.google.gson.Gson;
//
//import java.util.Arrays;
//import java.util.HashMap;
//import java.util.Map;
//
//import io.flutter.plugin.common.EventChannel;
//import io.flutter.plugin.common.MethodCall;
//import io.flutter.plugin.common.MethodChannel;
//import io.flutter.plugin.common.BinaryMessenger;
//import io.flutter.plugin.platform.PlatformView;
//
//public class StreamView implements PlatformView, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
//
//    private final LinearLayout layout;
//    private EventChannel.EventSink eventSink;
//    private BroadcastSession broadcastSession;
//    private AudioDevice audioDevice;
//    private final Context context;
//    private final Handler mainHandler;
//    private CameraDevice cameraDevice;
//    private CameraCaptureSession captureSession;
//    private CaptureRequest.Builder captureRequestBuilder;
//    private String defaultCameraType = "0";
//
//    private boolean isMuted = false;
//
//    StreamView(Context context, BinaryMessenger messenger) {
//        this.context = context;
//        layout = new LinearLayout(context);
//        mainHandler = new Handler(Looper.getMainLooper());
//
//        MethodChannel methodChannel = new MethodChannel(messenger, "ivs_broadcaster");
//        EventChannel eventChannel = new EventChannel(messenger, "ivs_broadcaster_event");
//
//        methodChannel.setMethodCallHandler(this);
//        eventChannel.setStreamHandler(this);
//        layout.setOnTouchListener((v, event) -> {
//            if (event.getAction() == MotionEvent.ACTION_DOWN) {
//                setFocusPoint(event, layout);
//            }
//            return true;
//        });
//    }
//
//    @Override
//    public View getView() {
//        return layout;
//    }
//
//    @Override
//    public void dispose() {
//        stopBroadcast();
//        releaseCamera();
//    }
//
//    // Define constants for method names
//    private static final String METHOD_START_PREVIEW = "startPreview";
//    private static final String METHOD_START_BROADCAST = "startBroadcast";
//    private static final String METHOD_GET_CAMERA_ZOOM_FACTOR = "getCameraZoomFactor";
//    private static final String METHOD_ZOOM_CAMERA = "zoomCamera";
//    private static final String METHOD_UPDATE_CAMERA_LENS = "updateCameraLens";
//    private static final String METHOD_MUTE = "mute";
//    private static final String METHOD_IS_MUTED = "isMuted";
//    private static final String METHOD_CHANGE_CAMERA = "changeCamera";
//    private static final String METHOD_GET_AVAILABLE_CAMERA_LENS = "getAvailableCameraLens";
//    private static final String METHOD_STOP_BROADCAST = "stopBroadcast";
//    private static final String METHOD_SET_FOCUS_MODE = "setFocusMode";
//    private static final String METHOD_CAPTURE_VIDEO = "captureVideo";
//    private static final String METHOD_STOP_VIDEO_CAPTURE = "stopVideoCapture";
//    private static final String METHOD_SEND_TIME_METADATA = "sendTimeMetaData";
//
//    // Define constants for argument keys
//    private static final String ARG_IMGSET = "imgset";
//    private static final String ARG_STREAM_KEY = "streamKey";
//    private static final String ARG_QUALITY = "quality";
//    private static final String ARG_AUTO_RECONNECT = "autoReconnect";
//    private static final String ARG_ZOOM = "zoom";
//    private static final String ARG_LENS = "lens";
//    private static final String ARG_TYPE = "type";
//    private static final String ARG_SECONDS = "seconds";
//
//
//    @Override
//    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
//        switch (call.method) {
//            case METHOD_START_PREVIEW:
//                startPreview(call.argument(ARG_IMGSET), call.argument(ARG_STREAM_KEY), call.argument(ARG_QUALITY), call.argument(ARG_AUTO_RECONNECT));
//                result.success(true);
//                break;
//            case METHOD_START_BROADCAST:
//                startBroadcast();
//                result.success("Broadcasting Started");
//                break;
//            case METHOD_STOP_BROADCAST:
//                stopBroadcast();
//                result.success("Broadcast Stopped");
//                break;
//            case METHOD_MUTE:
//                toggleMute();
//                result.success(isMuted ? "Muted" : "Unmuted");
//                break;
//            case METHOD_IS_MUTED:
//                result.success(isMuted);
//                break;
//            case METHOD_SEND_TIME_METADATA:
//                sendMetaData(call.argument("metadata"));
//                result.success(true);
//                break;
//            case METHOD_GET_CAMERA_ZOOM_FACTOR:
//                result.success(getCameraZoomFactor());
//                break;
//            case METHOD_ZOOM_CAMERA:
//                zoomCamera(call.argument(ARG_ZOOM));
//                result.success(true);
//                break;
//            case METHOD_CHANGE_CAMERA:
//                changeCamera(call.argument(ARG_TYPE));
//                result.success("Camera Changed");
//                break;
//            case METHOD_SET_FOCUS_MODE:
//                setFocusMode(call.argument(ARG_TYPE));
//                result.success(true);
//                break;
//            default:
//                result.notImplemented();
//                break;
//        }
//    }
//
//    private void setFocusPoint(MotionEvent event, View previewView) {
//        if (cameraDevice == null || captureRequestBuilder == null) {
//            Log.e("Camera2", "No Camera Device Available");
//            return;
//        }
//
//        // Check if the camera is in continuous autofocus mode
//        Integer currentFocusMode = captureRequestBuilder.get(CaptureRequest.CONTROL_AF_MODE);
//        if (currentFocusMode != null && currentFocusMode == CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE) {
//            Log.d("Camera2", "Camera is on Continuous Auto Focus. Set it to Auto Focus first.");
//            return;
//        }
//
//        // Get touch point
//        float tapX = event.getX();
//        float tapY = event.getY();
//
//        // Normalize touch point to [0,1] range
//        Rect sensorArraySize;
//        try {
//            CameraManager manager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
//            CameraCharacteristics characteristics = manager.getCameraCharacteristics(cameraDevice.getId());
//            sensorArraySize = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
//        } catch (CameraAccessException e) {
//            Log.e("Camera2", "Error accessing camera characteristics: " + e.getMessage());
//            return;
//        }
//
//        if (sensorArraySize == null) return;
//
//        float normalizedX = tapX / previewView.getWidth();
//        float normalizedY = tapY / previewView.getHeight();
//
//        int focusX = (int) (normalizedX * sensorArraySize.width());
//        int focusY = (int) (normalizedY * sensorArraySize.height());
//
//        MeteringRectangle focusArea = new MeteringRectangle(
//                new Point(focusX, focusY),
//                new Size(100, 100),
//                MeteringRectangle.METERING_WEIGHT_MAX
//        );
//
//        try {
//            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_REGIONS, new MeteringRectangle[]{focusArea});
//            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO);
//            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_START);
//
//            captureSession.setRepeatingRequest(captureRequestBuilder.build(), null, null);
//            Map<Object, Object> data = new HashMap<>();
//            data.put("foucsPoint", (tapX + "_" + tapY).toString());
//            sendEvent(data);
//            Log.d("Camera2", "Focus point set at: " + focusX + ", " + focusY);
//        } catch (CameraAccessException e) {
//            Log.e("Camera2", "Error setting focus point: " + e.getMessage());
//        }
//    }
//
//
//    private boolean setFocusMode(String type) {
//        if (cameraDevice == null || captureRequestBuilder == null) return false;
//
//        int focusMode;
//        switch (type) {
//            case "0":
//                focusMode = CaptureRequest.CONTROL_AF_MODE_OFF; // Locked focus
//                break;
//            case "1":
//                focusMode = CaptureRequest.CONTROL_AF_MODE_AUTO; // Auto focus
//                break;
//            case "2":
//                focusMode = CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE; // Continuous autofocus
//                break;
//            default:
//                Log.e("Camera2", "Invalid focus mode type");
//                return false;
//        }
//
//        try {
//            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, focusMode);
//            captureSession.setRepeatingRequest(captureRequestBuilder.build(), null, null);
//            return true;
//        } catch (CameraAccessException e) {
//            Log.e("Camera2", "Error setting focus mode: " + e.getMessage());
//            return false;
//        }
//    }
//
//
//    private void zoomCamera(Double zoomLevel) {
//        try {
//            CameraManager cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
//            CameraCharacteristics characteristics = cameraManager.getCameraCharacteristics(cameraDevice.getId());
//            Rect sensorArraySize = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
//            float maxZoom = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM);
//
//            if (zoomLevel < 1.0f) zoomLevel = 1.0;
//            if (zoomLevel > maxZoom) zoomLevel = (double) maxZoom;
//
//            int cropWidth = (int) (sensorArraySize.width() / zoomLevel);
//            int cropHeight = (int) (sensorArraySize.height() / zoomLevel);
//            int left = (sensorArraySize.width() - cropWidth) / 2;
//            int top = (sensorArraySize.height() - cropHeight) / 2;
//
//            Rect zoomRect = new Rect(left, top, left + cropWidth, top + cropHeight);
//            captureRequestBuilder.set(CaptureRequest.SCALER_CROP_REGION, zoomRect);
//            captureSession.setRepeatingRequest(captureRequestBuilder.build(), null, mainHandler);
//
//        } catch (CameraAccessException e) {
//            e.printStackTrace();
//        }
//    }
//
//    private Map<String, Object> getCameraZoomFactor() {
//        Map<String, Object> zoomData = new HashMap<>();
//
//        try {
//            CameraManager cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
//            if (cameraManager != null) {
//                String cameraId = cameraManager.getCameraIdList()[0]; // Use first available camera
//                CameraCharacteristics characteristics = cameraManager.getCameraCharacteristics(cameraId);
//
//                // Get maximum zoom level
//                float maxZoom = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM);
//                float minZoom = 1.0f; // Minimum zoom is always 1.0 (no zoom)
//
//                zoomData.put("minZoom", minZoom);
//                zoomData.put("maxZoom", maxZoom);
//            }
//        } catch (CameraAccessException e) {
//            Log.e("Camera Exception", e.getMessage());
//        }
//
//        return zoomData;
//    }
//
//    private void sendMetaData(String metadata) {
//        if (broadcastSession != null) {
//            broadcastSession.sendTimedMetadata(metadata);
//        }
//    }
//
//    private String streamUrl;
//    private String streamKey;
//    private String quality;
//    private Boolean autoReconnect;
//    private SurfaceSource source;
//
//    private void startPreview(String url, String key, String quality, Boolean autoReconnect) {
//        streamUrl = url;
//        streamKey = key;
//        this.autoReconnect = autoReconnect;
//        this.quality = quality;
//
//        BroadcastConfiguration config = getConfig(quality);
//        config.autoReconnect.setEnabled(autoReconnect);
//        config.mixer.slots = new BroadcastConfiguration.Mixer.Slot[]{BroadcastConfiguration.Mixer.Slot.with(slot -> {
//            slot.setPreferredAudioInput(Device.Descriptor.DeviceType.UNKNOWN);
//            slot.setPreferredVideoInput(Device.Descriptor.DeviceType.USER_IMAGE);
//            slot.setName("custom");
//            return slot;
//        }), BroadcastConfiguration.Mixer.Slot.with(slot -> {
//            slot.setzIndex(1);
//            slot.setAspect(BroadcastConfiguration.AspectMode.FILL);
//            slot.setSize(1920, 1080);
//            slot.setPosition(new BroadcastConfiguration.Vec2(config.video.getSize().x - 350, config.video.getSize().y - 350));
//            slot.setName("camera");
//            return slot;
//        })};
//        broadcastSession = new BroadcastSession(context, broadcastListener, config, Presets.Devices.MICROPHONE(context));
//        for (Device device : broadcastSession.listAttachedDevices()) {
//            if (device.getDescriptor().type == Device.Descriptor.DeviceType.MICROPHONE) {
//                audioDevice = (AudioDevice) device;
//            }
//        }
//        this.source = broadcastSession.createImageInputSource();
//        Surface ivsSurface = source.getInputSurface();
//        ImagePreviewView preview = broadcastSession.getPreviewView(BroadcastConfiguration.AspectMode.FILL);
//        preview.setLayoutParams(new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT));
//        layout.addView(preview);
//        startCamera2(ivsSurface);
//    }
//
//
//    private void startCamera2(Surface ivsSurface) {
//        CameraManager manager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
//        try {
//            if (ActivityCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
//                // Request camera permissions if not granted
//                ActivityCompat.requestPermissions((Activity) context, new String[]{Manifest.permission.CAMERA}, 100);
//                return;
//            }
//
//            // Fetch selected camera characteristics
//            CameraCharacteristics characteristics = manager.getCameraCharacteristics(defaultCameraType);
//            StreamConfigurationMap map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
//            Size[] sizes = map.getOutputSizes(SurfaceTexture.class);
//            Size previewSize = sizes[0]; // Choose an appropriate size
//
//            // Open camera
//            manager.openCamera(defaultCameraType, new CameraDevice.StateCallback() {
//                @Override
//                public void onOpened(@NonNull CameraDevice camera) {
//                    cameraDevice = camera;
//                    createCaptureSession(ivsSurface);
//                }
//
//                @Override
//                public void onDisconnected(@NonNull CameraDevice camera) {
//                    camera.close();
//                    cameraDevice = null;
//                }
//
//                @Override
//                public void onError(@NonNull CameraDevice camera, int error) {
//                    camera.close();
//                    cameraDevice = null;
//                    Log.e("Camera2", "Camera error: " + error);
//                }
//            }, mainHandler);
//
//        } catch (CameraAccessException e) {
//            Log.e("Camera2", "Camera access exception: " + e.getMessage());
//        }
//    }
//
//
//    private void createCaptureSession(Surface ivsSurface) {
//        try {
//            CaptureRequest.Builder captureRequestBuilder = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
//            this.captureRequestBuilder = captureRequestBuilder;
//            captureRequestBuilder.addTarget(ivsSurface);
//            cameraDevice.createCaptureSession(Arrays.asList(ivsSurface), new CameraCaptureSession.StateCallback() {
//                @Override
//                public void onConfigured(@NonNull CameraCaptureSession session) {
//                    captureSession = session;
//                    try {
//                        captureSession.setRepeatingRequest(captureRequestBuilder.build(), null, mainHandler);
//                    } catch (CameraAccessException e) {
//                        e.printStackTrace();
//                    }
//                }
//
//                @Override
//                public void onConfigureFailed(@NonNull CameraCaptureSession session) {
//                    Log.e("Camera2", "CaptureSession Configuration Failed");
//                }
//            }, mainHandler);
//        } catch (CameraAccessException e) {
//            e.printStackTrace();
//        }
//    }
//
//
//    private void startBroadcast() {
//        if (broadcastSession != null) {
//            broadcastSession.start(streamUrl, streamKey);
//        } else {
//            startPreview(streamUrl, streamKey, quality, autoReconnect);
//        }
//    }
//
//    private void stopBroadcast() {
//        if (broadcastSession != null) {
//            broadcastSession.stop();
//            broadcastSession.release();
//            broadcastSession = null;
//            Map<Object, Object> event = new HashMap<>();
//            event.put("state", "DISCONNECTED");
//            sendEvent(event);
//            layout.removeAllViews();
//        }
//        releaseCamera();
//    }
//
//    private void toggleMute() {
//        audioDevice.setGain(isMuted ? 1.F : 0.F);
//        isMuted = !isMuted;
//    }
//
//    private void changeCamera(String type) {
//        if (broadcastSession == null || cameraDevice == null) return;
//        CameraManager manager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
//        try {
//            for (String cameraId : manager.getCameraIdList()) {
//                CameraCharacteristics characteristics = manager.getCameraCharacteristics(cameraId);
//                int lensFacing = characteristics.get(CameraCharacteristics.LENS_FACING);
//
//                if ((type.equals("0") && lensFacing == CameraCharacteristics.LENS_FACING_FRONT) || (type.equals("1") && lensFacing == CameraCharacteristics.LENS_FACING_BACK)) {
//
//                    // Close the current camera
//                    releaseCamera();
//
//                    // Set the new camera ID
//                    defaultCameraType = cameraId;
//                    startCamera2(source.getInputSurface());
//                    return;
//                }
//            }
//        } catch (CameraAccessException e) {
//            e.printStackTrace();
//        }
//    }
//
//    private BroadcastConfiguration getConfig(String quality) {
//        BroadcastConfiguration config = new BroadcastConfiguration();
//        switch (quality) {
//            case "360":
//                config.video.setSize(640, 360);
//                config.video.setMaxBitrate(1000000);
//                config.video.setMinBitrate(500000);
//                config.video.setInitialBitrate(800000);
//                config.video.setTargetFramerate(30);
//                config.video.setKeyframeInterval(2);
//                break;
//            case "720":
//                config.video.setSize(1280, 720);
//                config.video.setMaxBitrate(3500000);
//                config.video.setMinBitrate(1500000);
//                config.video.setInitialBitrate(2500000);
//                config.video.setTargetFramerate(30);
//                config.video.setKeyframeInterval(2);
//                break;
//            case "1080":
//                config.video.setSize(1920, 1080);
//                config.video.setMaxBitrate(6000000);
//                config.video.setMinBitrate(4000000);
//                config.video.setInitialBitrate(5000000);
//                config.video.setTargetFramerate(30);
//                config.video.setKeyframeInterval(2);
//                break;
//            default:
//                config.video.setSize(1920, 1080);
//                config.video.setMaxBitrate(8500000);
//                config.video.setMinBitrate(1500000);
//                config.video.setInitialBitrate(2500000);
//                config.video.setTargetFramerate(30);
//                config.video.setKeyframeInterval(2);
//                break;
//        }
//        config.audio.setBitrate(128000);
//        return config;
//    }
//
//    private final BroadcastSession.Listener broadcastListener = new BroadcastSession.Listener() {
//        @Override
//        public void onStateChanged(@NonNull BroadcastSession.State state) {
//            Map<Object, Object> event = new HashMap<>();
//            event.put("state", state.name().toUpperCase());
//            sendEvent(event);
//        }
//
//        @Override
//        public void onRetryStateChanged(@NonNull BroadcastSession.RetryState state) {
//            Map<Object, Object> event = new HashMap<>();
//            event.put("retrystate", state.ordinal());
//            sendEvent(event);
//        }
//
//        @Override
//        public void onError(@NonNull BroadcastException exception) {
//            Map<Object, Object> event = new HashMap<>();
//            event.put("error", exception.getError().name());
//            sendEvent(event);
//        }
//
//        @Override
//        public void onTransmissionStatsChanged(@NonNull TransmissionStats stats) {
//            Map<Object, Object> event = new HashMap<>();
//            event.put("quality", stats.broadcastQuality.ordinal());
//            event.put("network", stats.networkHealth.ordinal());
//            sendEvent(event);
//        }
//    };
//
//    @Override
//    public void onListen(Object arguments, EventChannel.EventSink events) {
//        this.eventSink = events;
//    }
//
//    @Override
//    public void onCancel(Object arguments) {
//        this.eventSink = null;
//    }
//
//    private void sendEvent(Map<Object, Object> event) {
//        if (eventSink != null) {
//            Log.d("Send Event", "sendEvent: " + event.toString());
//            mainHandler.post(() -> eventSink.success(new Gson().toJson(event)));
//        }
//    }
//
//    private void releaseCamera() {
//        if (captureSession != null) {
//            captureSession.close();
//            captureSession = null;
//        }
//        if (cameraDevice != null) {
//            cameraDevice.close();
//            cameraDevice = null;
//        }
//    }
//}