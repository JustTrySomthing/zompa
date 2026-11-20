package io.tablecircle.prototype;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.util.Log;
import android.view.WindowManager;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.platform.PlatformView;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashSet;
import org.json.JSONObject;
import org.json.JSONArray;
import org.webrtc.*;
import org.webrtc.audio.JavaAudioDeviceModule;

final class VoicePeer {
    private final Activity activity;
    private final MethodChannel host;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AudioManager audio;
    private PeerConnectionFactory factory;
    private EglBase egl;
    private CallVideoView videoView;
    private Map<String, String> lastCallConnection = Collections.emptyMap();
    private boolean visible;
    private static final String TAG = "ZompadoCall";
    private Session session;
    private static boolean initialized;

    VoicePeer(Activity activity, MethodChannel host) {
        this.activity = activity;
        this.host = host;
        audio = activity.getSystemService(AudioManager.class);
    }

    void start(int token, String iceJson, String offer, MethodChannel.Result result) {
        if (session != null) {
            result.error("VOICE", "A call is already open.", null);
            return;
        }
        try {
            List<PeerConnection.IceServer> servers = iceServers(iceJson);

            if (factory == null) {
                if (!initialized) {
                    AppLog.record(activity, "WebRTC native initialization started");
                    PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions
                        .builder(activity.getApplicationContext())
                        .setEnableInternalTracer(false).createInitializationOptions());
                    initialized = true;
                    AppLog.record(activity, "WebRTC native initialization finished");
                }
                AppLog.record(activity, "Creating WebRTC audio device");
                JavaAudioDeviceModule device = JavaAudioDeviceModule.builder(activity.getApplicationContext())
                    .setAudioSource(android.media.MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                    .createAudioDeviceModule();
                try {
                    AppLog.record(activity, "Creating WebRTC peer factory");
                    // Keep the software codecs used by existing Zompado releases.
                    // Camera and rendering also use the call's own EGL context.
                    factory = PeerConnectionFactory.builder().setAudioDeviceModule(device)
                        .setVideoEncoderFactory(new SoftwareVideoEncoderFactory())
                        .setVideoDecoderFactory(new SoftwareVideoDecoderFactory())
                        .createPeerConnectionFactory();
                } finally {
                    device.release();
                }
            }

            Session active = new Session(token, result, audio.getMode(), audio.isSpeakerphoneOn());
            session = active;
            activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            var config = new PeerConnection.RTCConfiguration(servers);
            config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
            config.bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE;
            config.rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE;
            config.iceCandidatePoolSize = 1;
            config.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY;
            active.waitForRelay = servers.stream().flatMap(server -> server.urls.stream())
                .anyMatch(url -> url.startsWith("turn:") || url.startsWith("turns:"));
            AppLog.record(activity, "Creating WebRTC peer connection");
            active.peer = factory.createPeerConnection(config, active);
            if (active.peer == null) throw new IllegalStateException("No peer connection");
            active.peer.setAudioRecording(false);
            active.peer.setAudioPlayout(false);
            AppLog.record(activity, "Creating WebRTC audio input");
            active.source = factory.createAudioSource(new MediaConstraints());
            active.track = factory.createAudioTrack("zompado_voice", active.source);
            VoiceAudioService.begin(activity);
            AppLog.record(activity, offer == null ? "Preparing outgoing call offer" : "Preparing incoming call answer");
            active.start(offer);
        } catch (LinkageError | Exception failure) {
            AppLog.failure(activity, "Call media startup failed", failure);
            Log.w(TAG, "Call media startup failed.", failure);
            if (session != null) {
                session.fail("Couldn’t start voice audio.");
            } else {
                VoiceAudioService.finish(activity);
                result.error("VOICE", "Couldn’t start voice audio.", null);
            }
        }
    }

    // Use the Chatmail account's ICE service and Relay Lab's UDP/TCP TURN fallback.
    static List<PeerConnection.IceServer> iceServers(String iceJson) throws org.json.JSONException {
        List<PeerConnection.IceServer> servers = new ArrayList<>();
        JSONArray json = new JSONArray(iceJson);
        for (int i = 0; i < json.length(); i++) {
            JSONObject data = json.optJSONObject(i);
            if (data == null) continue;
            Object raw = data.opt("urls");
            JSONArray entries = raw instanceof JSONArray ? (JSONArray) raw : new JSONArray();
            if (raw instanceof String) entries.put(raw);
            var addresses = new LinkedHashSet<String>();
            for (int j = 0; j < entries.length(); j++) {
                String url = entries.optString(j);
                if (!url.matches("(?i)^(stun|stuns|turn|turns):\\S+$")) continue;
                addresses.add(url);
                if (url.startsWith("turn:") && !url.contains("?")) addresses.add(url + "?transport=tcp");
            }
            if (addresses.isEmpty()) continue;
            servers.add(PeerConnection.IceServer.builder(new ArrayList<>(addresses))
                .setUsername(data.optString("username", ""))
                .setPassword(data.optString("credential", "")).createIceServer());
        }
        return servers;
    }

    private EglBase.Context videoContext() {
        if (egl == null) egl = EglBase.create();
        return egl.getEglBaseContext();
    }

    PlatformView videoView() {
        try {
            var view = new CallVideoView(activity, videoContext());
            if (videoView != null) videoView.show(null, null, false, false);
            videoView = view;
            refreshVideo();
            return view;
        } catch (LinkageError | RuntimeException failure) {
            Log.w(TAG, "Could not initialize video rendering");
            return new PlatformView() {
                private final android.widget.FrameLayout placeholder = new android.widget.FrameLayout(activity);
                @Override public android.view.View getView() { return placeholder; }
                @Override public void dispose() {}
            };
        }
    }

    private void refreshVideo() {
        if (videoView == null) return;
        if (session == null) videoView.show(null, null, false, false);
        else videoView.show(session.camera == null ? null : session.camera.track,
            session.remoteVideo, session.cameraEnabled() && session.selfPreview, session.remoteCamera);
    }

    boolean camera(int token, boolean enabled) {
        Session active = session;
        if (active == null || token != active.token || !active.mediaStarted || !active.videoNegotiated) return false;
        if (enabled && (activity.checkSelfPermission(Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED || !visible)) return false;
        try {
            if (enabled && !active.startCamera()) return false;
            if (!enabled && active.camera != null) active.camera.stop();
            active.sendMediaState();
            refreshVideo();
            active.status(enabled ? "cameraOn" : "cameraOff", null);
            return true;
        } catch (LinkageError | RuntimeException failure) {
            Log.w(TAG, "Call camera startup failed.", failure);
            if (active.camera != null) active.camera.stop();
            active.sendMediaState();
            refreshVideo();
            return false;
        }
    }

    Map<String, String> lastCallConnection() {
        return lastCallConnection;
    }

    void selfPreview(boolean visible) {
        if (session == null) return;
        session.selfPreview = visible;
        refreshVideo();
    }

    void setVisible(boolean active) {
        visible = active;
        if (!active) suspendCamera();
    }

    private void suspendCamera() {
        if (session != null && session.cameraEnabled()) camera(session.token, false);
    }

    void answer(int token, String answer, MethodChannel.Result result) {
        Session active = session;
        if (active == null || token != active.token) {
            result.error("VOICE", "The call ended.", null);
            return;
        }
        active.peer.setRemoteDescription(new Sdp() {
            @Override public void onSetSuccess() {
                main.post(() -> {
                    if (session == active) active.remoteDescription(answer);
                    result.success(null);
                });
            }
            @Override public void onSetFailure(String ignored) {
                main.post(() -> result.error("VOICE", "Couldn’t connect this call.", null));
            }
        }, new SessionDescription(SessionDescription.Type.ANSWER, answer));
    }

    boolean mute(int token, boolean muted) {
        if (session == null || session.token != token || session.track == null
                || !session.track.setEnabled(!muted)) return false;
        session.sendMediaState();
        return true;
    }

    boolean speaker(int token, boolean speaker) {
        return session != null && session.token == token && session.setSpeaker(speaker);
    }

    void end(int token) {
        if (session != null && session.token == token) end();
    }

    void end() {
        Session old = session;
        session = null;
        refreshVideo();
        if (old != null) old.close();
        VoiceAudioService.finish(activity);
        activity.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    void dispose() {
        end();
        if (factory != null) factory.dispose();
        factory = null;
        if (videoView != null) videoView.dispose();
        videoView = null;
        if (egl != null) egl.release();
        egl = null;
    }

    private class Session implements PeerConnection.Observer {
        final int token;
        final int oldAudioMode;
        final boolean oldSpeaker;
        MethodChannel.Result preparing;
        PeerConnection peer;
        AudioSource source;
        AudioTrack track;
        CallCamera camera;
        RtpSender videoSender;
        VideoTrack remoteVideo;
        boolean videoNegotiated;
        boolean remoteCamera;
        boolean selfPreview = true;
        DataChannel trickle;
        DataChannel mediaState;
        final List<IceCandidate> gatheredCandidates = new ArrayList<>();
        boolean waitForRelay;
        boolean relayCandidate;
        boolean remoteUdpRelay;
        boolean mediaStarted;
        AudioFocusRequest focus;
        final AudioDeviceInfo priorDevice = Build.VERSION.SDK_INT >= 31
            ? audio.getCommunicationDevice() : null;
        final Runnable iceTimeout = () -> sendDescription(true);
        boolean callerRelayGraceElapsed;
        final Runnable answerWithRemoteRelay = () -> {
            callerRelayGraceElapsed = true;
            sendDescription(false, true);
        };
        final Runnable lostConnection = () -> fail("The call lost its connection.");
        boolean localSet;

        Session(int token, MethodChannel.Result preparing, int oldAudioMode, boolean oldSpeaker) {
            this.token = token;
            this.preparing = preparing;
            this.oldAudioMode = oldAudioMode;
            this.oldSpeaker = oldSpeaker;
        }

        void start(String offer) {
            if (offer == null) {
                setupChannels();
                addLocalTracks(false, true);
                createDescription(true);
            } else {
                peer.setRemoteDescription(new Sdp() {
                    @Override public void onSetSuccess() {
                        main.post(() -> {
                            if (session != Session.this) return;
                            try {
                                remoteUdpRelay = UDP_RELAY_CANDIDATE.matcher(offer).find();
                                remoteDescription(offer);
                                if (hasMedia(offer, "application")) setupChannels();
                                addLocalTracks(true, videoNegotiated);
                                createDescription(false);
                            } catch (RuntimeException failure) {
                                fail("Couldn’t prepare this call.");
                            }
                        });
                    }
                    @Override public void onSetFailure(String ignored) {
                        main.post(() -> fail("Couldn’t read the call offer."));
                    }
                }, new SessionDescription(SessionDescription.Type.OFFER, offer));
            }
        }

        void addLocalTracks(boolean answering, boolean withVideo) {
            var streams = Collections.singletonList("zompado");
            if (peer.addTrack(track, streams) == null) {
                throw new IllegalStateException("No audio sender");
            }
            if (!withVideo) return;

            // Negotiate two-way video without creating its source on a voice call.
            var direction = RtpTransceiver.RtpTransceiverDirection.SEND_RECV;
            var mediaType = MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO;
            if (answering) {
                for (RtpTransceiver offered : peer.getTransceivers()) {
                    if (offered.getMediaType() == mediaType) {
                        offered.setDirection(direction);
                        videoSender = offered.getSender();
                        break;
                    }
                }
            } else {
                RtpTransceiver video = peer.addTransceiver(mediaType,
                    new RtpTransceiver.RtpTransceiverInit(direction, streams));
                if (video != null) videoSender = video.getSender();
            }
            if (videoSender == null) throw new IllegalStateException("No video sender");
        }

        boolean cameraEnabled() {
            return camera != null && camera.enabled();
        }

        boolean startCamera() {
            if (videoSender == null) return false;
            if (camera == null) {
                CallCamera next = new CallCamera(activity, factory, () -> main.post(() -> {
                    if (session != this) return;
                    suspendCamera();
                    status("cameraError", "Couldn’t start or keep the camera open.");
                }));
                if (!videoSender.setTrack(next.track, false)) {
                    next.dispose();
                    return false;
                }
                camera = next;
            }
            return camera.start(videoContext());
        }

        void remoteDescription(String description) {
            videoNegotiated = hasMedia(description, "video");
            status(videoNegotiated ? "videoAvailable" : "videoUnavailable", null);
        }

        void setupChannels() {
            // Negotiated IDs and payloads match Delta Chat's call client.
            trickle = channel("iceTrickling", 1, this::flushCandidates, json -> {
                String value = json.getString("candidate");
                int index = json.getInt("sdpMLineIndex");
                if (value.length() <= 4096 && index >= 0 && index <= 2) {
                    peer.addIceCandidate(new IceCandidate(json.getString("sdpMid"), index, value));
                }
            });
            mediaState = channel("mutedState", 3, this::sendMediaState, json -> {
                remoteCamera = json.getBoolean("videoEnabled");
                refreshVideo();
                status(remoteCamera ? "remoteCameraOn" : "remoteCameraOff", null);
            });
        }

        DataChannel channel(String name, int id, Runnable open, JsonMessage receive) {
            var init = new DataChannel.Init();
            init.negotiated = true;
            init.id = id;
            var channel = peer.createDataChannel(name, init);
            if (channel == null) return null;
            channel.registerObserver(new DataChannel.Observer() {
                @Override public void onBufferedAmountChange(long ignored) {}

                @Override public void onStateChange() {
                    main.post(() -> {
                        if (session == Session.this && channel.state() == DataChannel.State.OPEN) open.run();
                    });
                }

                @Override public void onMessage(DataChannel.Buffer buffer) {
                    if (buffer.binary || buffer.data.remaining() > 8192) return;
                    byte[] bytes = new byte[buffer.data.remaining()];
                    buffer.data.get(bytes);
                    main.post(() -> {
                        if (session != Session.this) return;
                        try {
                            receive.read(new JSONObject(new String(bytes, StandardCharsets.UTF_8)));
                        } catch (org.json.JSONException | RuntimeException ignored) {
                            // Ignore malformed control frames. Media remains connected.
                        }
                    });
                }
            });
            return channel;
        }

        void sendMediaState() {
            if (!isOpen(mediaState)) return;
            try {
                sendJson(mediaState, new JSONObject().put("audioEnabled", track.enabled())
                    .put("videoEnabled", cameraEnabled()));
            } catch (org.json.JSONException ignored) {}
        }

        void flushCandidates() {
            if (!isOpen(trickle)) return;
            for (var candidate : gatheredCandidates) {
                try {
                    sendJson(trickle, new JSONObject().put("candidate", candidate.sdp)
                        .put("sdpMid", candidate.sdpMid).put("sdpMLineIndex", candidate.sdpMLineIndex));
                } catch (org.json.JSONException ignored) {}
            }
            gatheredCandidates.clear();
        }

        void createDescription(boolean offer) {
            Sdp callback = new Sdp() {
                @Override public void onCreateSuccess(SessionDescription description) {
                    main.post(() -> {
                        if (session != Session.this) return;
                        peer.setLocalDescription(new Sdp() {
                            @Override public void onSetSuccess() {
                                main.post(() -> {
                                    if (session != Session.this) return;
                                    localSet = true;
                                    if (relayCandidate ||
                                            peer.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE) {
                                        sendDescription(false);
                                    }
                                    if (preparing != null) {
                                        // The caller's relay can complete ICE with a local UDP candidate.
                                        // Give local TURN a short head start, then signal the answer.
                                        if (remoteUdpRelay) main.postDelayed(answerWithRemoteRelay, 1500);
                                        main.postDelayed(iceTimeout, 12000);
                                    }
                                });
                            }
                            @Override public void onSetFailure(String ignored) {
                                main.post(() -> fail("Couldn’t prepare voice audio."));
                            }
                        }, description);
                    });
                }
                @Override public void onCreateFailure(String ignored) {
                    main.post(() -> fail("Couldn’t prepare voice audio."));
                }
            };
            if (offer) peer.createOffer(callback, new MediaConstraints());
            else peer.createAnswer(callback, new MediaConstraints());
        }

        void sendDescription(boolean deadline) {
            sendDescription(deadline, false);
        }

        void sendDescription(boolean deadline, boolean useRemoteRelay) {
            if (session != this || preparing == null || !localSet) return;
            var description = peer.getLocalDescription();
            if (description == null && !deadline) return;
            if (description == null || !description.description.contains("a=ice-ufrag:")
                    || !description.description.contains("a=ice-pwd:")) {
                fail("Couldn’t prepare a network connection for the call.");
                return;
            }
            // As in Delta Chat, signal a valid description even after the ICE
            // deadline. The other endpoint can still connect via its own relay.
            String sdp = description.description;
            if (useRemoteRelay && !UDP_CANDIDATE.matcher(sdp).find()) return;
            if (!sdp.contains("a=candidate:")) {
                if (!deadline) return;
                Log.w(TAG, "Initial ICE timed out without embedded candidates");
            }
            main.removeCallbacks(iceTimeout);
            main.removeCallbacks(answerWithRemoteRelay);
            var result = preparing;
            preparing = null;
            AppLog.record(activity, "Local call " + description.type.canonicalForm()
                + " prepared · local relay " + relayCandidate
                + (useRemoteRelay ? " · using caller relay" : deadline ? " · ICE deadline" : ""));
            Log.i(TAG, "Local " + description.type.canonicalForm() + " ICE candidates: "
                + gatheredCandidates.size() + " (relay: " + relayCandidate + ")");
            result.success(sdp);
        }

        void fail(String message) {
            if (session != this) return;
            if (preparing != null) {
                var result = preparing;
                preparing = null;
                result.error("VOICE", message, null);
            } else {
                status("failed", message);
            }
            end();
        }

        void status(String state, String message) {
            var data = new HashMap<String, Object>();
            data.put("token", token);
            data.put("status", state);
            if (message != null) data.put("message", message);
            host.invokeMethod("voiceStatus", data);
        }

        @SuppressWarnings("deprecation")
        boolean setSpeaker(boolean useSpeaker) {
            if (Build.VERSION.SDK_INT >= 31) {
                int preferred = useSpeaker ? AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    : AudioDeviceInfo.TYPE_BUILTIN_EARPIECE;
                for (AudioDeviceInfo device : audio.getAvailableCommunicationDevices()) {
                    if (device.getType() == preferred) return audio.setCommunicationDevice(device);
                }
                if (!useSpeaker) audio.clearCommunicationDevice();
                return !useSpeaker;
            }
            audio.setSpeakerphoneOn(useSpeaker);
            return true;
        }

        @SuppressWarnings("deprecation")
        void close() {
            main.removeCallbacks(iceTimeout);
            main.removeCallbacks(answerWithRemoteRelay);
            main.removeCallbacks(lostConnection);
            if (preparing != null) {
                preparing.error("VOICE", "Call ended.", null);
                preparing = null;
            }
            if (camera != null) camera.stop();
            closeChannel(trickle);
            closeChannel(mediaState);
            if (peer != null) {
                peer.setAudioPlayout(false);
                peer.setAudioRecording(false);
                peer.dispose();
            }
            if (camera != null) camera.dispose();
            if (track != null) track.dispose();
            if (source != null) source.dispose();
            if (focus != null && Build.VERSION.SDK_INT >= 26) audio.abandonAudioFocusRequest(focus);
            if (Build.VERSION.SDK_INT >= 31) {
                audio.clearCommunicationDevice();
                if (priorDevice != null) audio.setCommunicationDevice(priorDevice);
            } else audio.setSpeakerphoneOn(oldSpeaker);
            audio.setMode(oldAudioMode);
        }

        @Override public void onIceGatheringChange(PeerConnection.IceGatheringState state) {
            if (state == PeerConnection.IceGatheringState.COMPLETE) main.post(() -> sendDescription(false));
        }

        @Override public void onConnectionChange(PeerConnection.PeerConnectionState state) {
            main.post(() -> {
                if (session != this) return;
                AppLog.record(activity, "WebRTC connection " + state);
                Log.i(TAG, "Peer connection: " + state);
                if (state == PeerConnection.PeerConnectionState.CONNECTED) {
                    main.removeCallbacks(lostConnection);
                    if (!mediaStarted) {
                        try {
                            audio.setMode(AudioManager.MODE_IN_COMMUNICATION);
                            setSpeaker(false);
                            if (Build.VERSION.SDK_INT >= 26) {
                                focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                                    .setAudioAttributes(new AudioAttributes.Builder()
                                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                                    .setOnAudioFocusChangeListener(change -> {})
                                    .build();
                                audio.requestAudioFocus(focus);
                            }
                            peer.setAudioPlayout(true);
                            peer.setAudioRecording(true);
                            mediaStarted = true;
                        } catch (RuntimeException failure) {
                            AppLog.failure(activity, "Call audio device failed", failure);
                            fail("Couldn’t start the call’s audio device.");
                            return;
                        }
                    }
                    status("connected", null);
                    peer.getStats(report -> main.post(() -> {
                        if (session == this) recordCallConnection(report);
                    }));
                } else if (state == PeerConnection.PeerConnectionState.FAILED) {
                    fail("Couldn’t connect voice audio.");
                } else if (state == PeerConnection.PeerConnectionState.DISCONNECTED) {
                    main.removeCallbacks(lostConnection);
                    main.postDelayed(lostConnection, 10000);
                }
            });
        }

        void recordCallConnection(RTCStatsReport report) {
            var stats = report.getStatsMap();
            for (var transport : stats.values()) {
                if (!"transport".equals(transport.getType())) continue;
                var pair = stats.get(transport.getMembers().get("selectedCandidatePairId"));
                if (pair == null) continue;
                var local = stats.get(pair.getMembers().get("localCandidateId"));
                var remote = stats.get(pair.getMembers().get("remoteCandidateId"));
                if (local == null || remote == null) continue;
                var mine = local.getMembers();
                var theirs = remote.getMembers();
                var connection = new HashMap<String, String>();
                Object protocol = mine.get("relayProtocol");
                if (!(protocol instanceof String)) protocol = mine.get("protocol");
                if (protocol instanceof String value) connection.put("protocol", value.toUpperCase(java.util.Locale.ROOT));
                var relay = "relay".equals(mine.get("candidateType")) ? mine
                    : "relay".equals(theirs.get("candidateType")) ? theirs : null;
                if (relay != null && relay.get("address") instanceof String address) {
                    connection.put("relay", address);
                }
                lastCallConnection = connection;
                return;
            }
        }

        @Override public void onIceCandidate(IceCandidate candidate) {
            main.post(() -> {
                if (session != this) return;
                if (gatheredCandidates.size() < 256) gatheredCandidates.add(candidate);
                flushCandidates();
                if (candidate.sdp.contains(" typ relay ")) relayCandidate = true;
                if (!waitForRelay || relayCandidate) sendDescription(false);
                else if (callerRelayGraceElapsed) sendDescription(false, true);
            });
        }
        @Override public void onTrack(RtpTransceiver transceiver) {
            if (transceiver.getReceiver().track() instanceof VideoTrack video) {
                main.post(() -> {
                    if (session != this) return;
                    remoteVideo = video;
                    refreshVideo();
                });
            }
        }
        @Override public void onIceCandidateError(IceCandidateErrorEvent error) {
            Log.w(TAG, "ICE server error " + error.errorCode);
        }
        @Override public void onIceCandidatesRemoved(IceCandidate[] candidates) {}
        @Override public void onSignalingChange(PeerConnection.SignalingState state) {}
        @Override public void onIceConnectionChange(PeerConnection.IceConnectionState state) {}
        @Override public void onIceConnectionReceivingChange(boolean receiving) {}
        @Override public void onAddStream(MediaStream stream) {}
        @Override public void onRemoveStream(MediaStream stream) {}
        @Override public void onDataChannel(DataChannel channel) {
            main.post(channel::dispose);
        }
        @Override public void onRenegotiationNeeded() {}
    }

    private interface JsonMessage {
        void read(JSONObject message) throws org.json.JSONException;
    }

    private static final java.util.regex.Pattern UDP_CANDIDATE = java.util.regex.Pattern
        .compile("(?im)^a=candidate:[^ \\r\\n]+ 1 udp ");
    private static final java.util.regex.Pattern UDP_RELAY_CANDIDATE = java.util.regex.Pattern
        .compile(UDP_CANDIDATE.pattern() + "[^\\r\\n]+ typ relay(?: |$)");

    private static boolean hasMedia(String sdp, String media) {
        return java.util.regex.Pattern.compile("(?m)^m=" + media + " [1-9][0-9]* ")
            .matcher(sdp).find();
    }

    private static boolean isOpen(DataChannel channel) {
        return channel != null && channel.state() == DataChannel.State.OPEN;
    }

    private static void sendJson(DataChannel channel, JSONObject json) {
        channel.send(new DataChannel.Buffer(ByteBuffer.wrap(
            json.toString().getBytes(StandardCharsets.UTF_8)), false));
    }

    private static void closeChannel(DataChannel channel) {
        if (channel == null) return;
        channel.unregisterObserver();
        channel.close();
        channel.dispose();
    }

    private abstract static class Sdp implements SdpObserver {
        @Override public void onCreateSuccess(SessionDescription description) {}
        @Override public void onSetSuccess() {}
        @Override public void onCreateFailure(String ignored) {}
        @Override public void onSetFailure(String ignored) {}
    }
}
