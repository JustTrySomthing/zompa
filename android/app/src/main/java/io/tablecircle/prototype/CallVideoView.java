package io.tablecircle.prototype;

import android.content.Context;
import android.graphics.Color;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import io.flutter.plugin.platform.PlatformView;
import org.webrtc.EglBase;
import org.webrtc.RendererCommon;
import org.webrtc.SurfaceViewRenderer;
import org.webrtc.VideoTrack;

final class CallVideoView implements PlatformView {
    private final FrameLayout frame;
    private final SurfaceViewRenderer remote;
    private final SurfaceViewRenderer local;
    private final FrameLayout.LayoutParams inset;
    private VideoTrack localTrack;
    private VideoTrack remoteTrack;
    private boolean disposed;

    CallVideoView(Context context, EglBase.Context egl) {
        frame = new FrameLayout(context);
        frame.setBackgroundColor(Color.BLACK);
        remote = new SurfaceViewRenderer(context);
        local = new SurfaceViewRenderer(context);
        local.setZOrderMediaOverlay(true);
        local.setMirror(true);
        remote.init(egl, new RendererCommon.RendererEvents() {
            @Override public void onFirstFrameRendered() {
                Log.i("ZompadoCall", "Remote camera frame rendered");
            }
            @Override public void onFrameResolutionChanged(int width, int height, int rotation) {}
        });
        local.init(egl, null);
        remote.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT);
        local.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT);
        frame.addView(remote, new FrameLayout.LayoutParams(-1, -1));
        float density = context.getResources().getDisplayMetrics().density;
        inset = new FrameLayout.LayoutParams(Math.round(108 * density),
            Math.round(144 * density), Gravity.END | Gravity.BOTTOM);
        inset.setMargins(0, 0, Math.round(12 * density), Math.round(12 * density));
        frame.addView(local, new FrameLayout.LayoutParams(-1, -1));
    }

    void show(VideoTrack mine, VideoTrack theirs, boolean showMine, boolean showTheirs) {
        if (disposed) return;
        if (!showMine) mine = null;
        if (!showTheirs) theirs = null;
        if (localTrack != mine) {
            if (localTrack != null) localTrack.removeSink(local);
            if (mine != null) mine.addSink(local);
            localTrack = mine;
        }
        if (remoteTrack != theirs) {
            if (remoteTrack != null) remoteTrack.removeSink(remote);
            if (theirs != null) theirs.addSink(remote);
            remoteTrack = theirs;
        }
        local.setLayoutParams(theirs == null ? new FrameLayout.LayoutParams(-1, -1) : inset);
        local.setVisibility(mine == null ? View.INVISIBLE : View.VISIBLE);
        remote.setVisibility(theirs == null ? View.INVISIBLE : View.VISIBLE);
    }

    @Override public View getView() {
        return frame;
    }

    @Override public void dispose() {
        if (disposed) return;
        show(null, null, false, false);
        disposed = true;
        local.release();
        remote.release();
    }
}
