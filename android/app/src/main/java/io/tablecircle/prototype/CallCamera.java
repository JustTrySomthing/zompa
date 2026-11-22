package io.tablecircle.prototype;

import android.content.Context;
import org.webrtc.Camera1Enumerator;
import org.webrtc.Camera2Enumerator;
import org.webrtc.CameraEnumerator;
import org.webrtc.CameraVideoCapturer;
import org.webrtc.EglBase;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoSource;
import org.webrtc.VideoTrack;

/** Owns the local video track and camera capture while video is available. */
final class CallCamera {
    private final Context context;
    private final Runnable onFailure;
    private final VideoSource source;
    final VideoTrack track;
    private CameraVideoCapturer capturer;
    private SurfaceTextureHelper texture;

    CallCamera(Context context, PeerConnectionFactory factory, Runnable onFailure) {
        this.context = context.getApplicationContext();
        this.onFailure = onFailure;
        source = factory.createVideoSource(false);
        track = factory.createVideoTrack("zompa_camera", source);
        track.setEnabled(false);
    }

    boolean start(EglBase.Context egl) {
        if (enabled()) return true;
        CameraEnumerator cameras = Camera2Enumerator.isSupported(context)
            ? new Camera2Enumerator(context) : new Camera1Enumerator(true);
        String[] names = cameras.getDeviceNames();
        if (names.length == 0) return false;
        String device = names[0];
        for (String name : names) {
            if (cameras.isFrontFacing(name)) {
                device = name;
                break;
            }
        }
        capturer = cameras.createCapturer(device, new CameraVideoCapturer.CameraEventsHandler() {
            @Override public void onCameraError(String ignored) { onFailure.run(); }
            @Override public void onCameraDisconnected() { onFailure.run(); }
            @Override public void onCameraFreezed(String ignored) { onFailure.run(); }
            @Override public void onCameraOpening(String ignored) {}
            @Override public void onFirstFrameAvailable() {}
            @Override public void onCameraClosed() {}
        });
        if (capturer == null) return false;
        texture = SurfaceTextureHelper.create("ZompaCamera", egl);
        if (texture == null) {
            stop();
            return false;
        }
        capturer.initialize(texture, context, source.getCapturerObserver());
        capturer.startCapture(640, 480, 24);
        track.setEnabled(true);
        return true;
    }

    boolean enabled() {
        return track.enabled();
    }

    void stop() {
        track.setEnabled(false);
        if (capturer != null) {
            try {
                capturer.stopCapture();
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            } finally {
                capturer.dispose();
                capturer = null;
            }
        }
        if (texture != null) {
            texture.dispose();
            texture = null;
        }
    }

    void dispose() {
        track.dispose();
        source.dispose();
    }
}
