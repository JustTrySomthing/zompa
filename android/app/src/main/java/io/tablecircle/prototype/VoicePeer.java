package io.tablecircle.prototype;

import android.app.Activity;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.List;
import java.util.Collections;
import java.util.HashMap;
import org.json.JSONArray;
import org.webrtc.*;
import org.webrtc.audio.JavaAudioDeviceModule;

final class VoicePeer {
    private final Activity activity;
    private final MethodChannel host;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AudioManager audio;
    private PeerConnectionFactory factory;
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
            List<PeerConnection.IceServer> servers = new ArrayList<>();
            JSONArray json = new JSONArray(iceJson);
            for (int i = 0; i < json.length(); i++) {
                var data = json.getJSONObject(i);
                JSONArray urls = data.getJSONArray("urls");
                if (urls.length() == 0) continue;
                List<String> addresses = new ArrayList<>();
                for (int j = 0; j < urls.length(); j++) addresses.add(urls.getString(j));
                var builder = PeerConnection.IceServer.builder(addresses);
                if (!data.isNull("username")) builder.setUsername(data.getString("username"));
                if (!data.isNull("credential")) builder.setPassword(data.getString("credential"));
                servers.add(builder.createIceServer());
            }

            if (factory == null) {
                if (!initialized) {
                    PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions
                        .builder(activity.getApplicationContext()).createInitializationOptions());
                    initialized = true;
                }
                JavaAudioDeviceModule device = JavaAudioDeviceModule.builder(activity.getApplicationContext())
                    .setAudioSource(android.media.MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                    .createAudioDeviceModule();
                try {
                    // Delta Chat reserves a video section even on voice calls. Give
                    // WebRTC a codec list to parse it before our answer rejects video.
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
            audio.setMode(AudioManager.MODE_IN_COMMUNICATION);
            active.setSpeaker(false);
            var config = new PeerConnection.RTCConfiguration(servers);
            config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
            active.peer = factory.createPeerConnection(config, active);
            if (active.peer == null) throw new IllegalStateException("No peer connection");
            active.source = factory.createAudioSource(new MediaConstraints());
            active.track = factory.createAudioTrack("zompado_voice", active.source);
            if (active.peer.addTrack(active.track, Collections.singletonList("zompado")) == null) {
                throw new IllegalStateException("No audio sender");
            }
            VoiceAudioService.begin(activity);
            active.start(offer);
        } catch (LinkageError | Exception failure) {
            if (session != null) {
                session.fail("Couldn’t start voice audio.");
            } else {
                VoiceAudioService.finish(activity);
                result.error("VOICE", "Couldn’t start voice audio.", null);
            }
        }
    }

    void answer(int token, String answer, MethodChannel.Result result) {
        Session active = session;
        if (active == null || token != active.token) {
            result.error("VOICE", "The call ended.", null);
            return;
        }
        active.peer.setRemoteDescription(new Sdp() {
            @Override public void onSetSuccess() {
                main.post(() -> result.success(null));
            }
            @Override public void onSetFailure(String ignored) {
                main.post(() -> result.error("VOICE", "Couldn’t connect this call.", null));
            }
        }, new SessionDescription(SessionDescription.Type.ANSWER, answer));
    }

    boolean mute(int token, boolean muted) {
        return session != null && session.token == token && session.track != null
            && session.track.setEnabled(!muted);
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
        if (old != null) old.close();
        VoiceAudioService.finish(activity);
    }

    void dispose() {
        end();
        if (factory != null) factory.dispose();
        factory = null;
    }

    private class Session implements PeerConnection.Observer {
        final int token;
        final int oldAudioMode;
        final boolean oldSpeaker;
        MethodChannel.Result preparing;
        PeerConnection peer;
        AudioSource source;
        AudioTrack track;
        final Runnable iceTimeout = () -> sendDescription();
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
                createDescription(true);
            } else {
                peer.setRemoteDescription(new Sdp() {
                    @Override public void onSetSuccess() {
                        main.post(() -> {
                            if (session != Session.this) return;
                            // Delta Chat reserves a video track in an audio call.
                            // Reject that track in our answer without starting a camera.
                            for (RtpTransceiver transceiver : peer.getTransceivers()) {
                                if (transceiver.getMediaType() == MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO) {
                                    transceiver.stop();
                                }
                            }
                            createDescription(false);
                        });
                    }
                    @Override public void onSetFailure(String ignored) {
                        main.post(() -> fail("Couldn’t read the call offer."));
                    }
                }, new SessionDescription(SessionDescription.Type.OFFER, offer));
            }
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
                                    if (peer.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE) {
                                        sendDescription();
                                    } else {
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

        void sendDescription() {
            if (session != this || preparing == null || !localSet) return;
            var description = peer.getLocalDescription();
            if (description == null || (!description.description.contains("a=candidate:")
                    && (description.type != SessionDescription.Type.ANSWER
                        || !description.description.contains("a=ice-ufrag:")
                        || !description.description.contains("a=ice-pwd:")))) {
                fail("No network path for voice audio was found.");
                return;
            }
            main.removeCallbacks(iceTimeout);
            var result = preparing;
            preparing = null;
            result.success(description.description);
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
                if (!useSpeaker) {
                    audio.clearCommunicationDevice();
                    return true;
                }
                for (AudioDeviceInfo device : audio.getAvailableCommunicationDevices()) {
                    if (device.getType() == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
                        return audio.setCommunicationDevice(device);
                    }
                }
                return false;
            }
            audio.setSpeakerphoneOn(useSpeaker);
            return true;
        }

        @SuppressWarnings("deprecation")
        void close() {
            main.removeCallbacks(iceTimeout);
            main.removeCallbacks(lostConnection);
            if (preparing != null) {
                preparing.error("VOICE", "Call ended.", null);
                preparing = null;
            }
            if (peer != null) peer.dispose();
            if (track != null) track.dispose();
            if (source != null) source.dispose();
            if (Build.VERSION.SDK_INT >= 31) audio.clearCommunicationDevice();
            else audio.setSpeakerphoneOn(oldSpeaker);
            audio.setMode(oldAudioMode);
        }

        @Override public void onIceGatheringChange(PeerConnection.IceGatheringState state) {
            if (state == PeerConnection.IceGatheringState.COMPLETE) main.post(() -> sendDescription());
        }

        @Override public void onConnectionChange(PeerConnection.PeerConnectionState state) {
            main.post(() -> {
                if (session != this) return;
                if (state == PeerConnection.PeerConnectionState.CONNECTED) {
                    main.removeCallbacks(lostConnection);
                    status("connected", null);
                } else if (state == PeerConnection.PeerConnectionState.FAILED) {
                    fail("Couldn’t connect voice audio.");
                } else if (state == PeerConnection.PeerConnectionState.DISCONNECTED) {
                    main.removeCallbacks(lostConnection);
                    main.postDelayed(lostConnection, 10000);
                }
            });
        }

        @Override public void onIceCandidate(IceCandidate candidate) {}
        @Override public void onIceCandidatesRemoved(IceCandidate[] candidates) {}
        @Override public void onSignalingChange(PeerConnection.SignalingState state) {}
        @Override public void onIceConnectionChange(PeerConnection.IceConnectionState state) {}
        @Override public void onIceConnectionReceivingChange(boolean receiving) {}
        @Override public void onAddStream(MediaStream stream) {}
        @Override public void onRemoveStream(MediaStream stream) {}
        @Override public void onDataChannel(DataChannel channel) {}
        @Override public void onRenegotiationNeeded() {}
    }

    private abstract static class Sdp implements SdpObserver {
        @Override public void onCreateSuccess(SessionDescription description) {}
        @Override public void onSetSuccess() {}
        @Override public void onCreateFailure(String ignored) {}
        @Override public void onSetFailure(String ignored) {}
    }
}
