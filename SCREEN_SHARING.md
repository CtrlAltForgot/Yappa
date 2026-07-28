# Yappa Screen Sharing

## Purpose

This is the architecture, status, and handoff document for desktop capture,
desktop audio, LiveKit publication, and screen-sharing UI state. Read it before
changing any of those areas and update it whenever behavior or plans change.

Last updated: 2026-07-24.

Realtime media E2EE is specified in `MEDIA_E2EE.md` and its device registry,
room-key coordination, signed envelope relay, epoch rotation, and LiveKit GCM
activation are implemented locally. Screen video and screen/system audio use
the same mandatory client-held room epoch key as microphone and camera media
because the encryption provider is installed on the LiveKit room before any
track publication. Frames are discarded when a cryptor lacks a key, and epoch
changes first install a temporary quarantine key rather than continuing with a
key known to a removed device. Any coordination verification failure also
zeroizes the room key and disables every local publication, including screen
video and system audio. Delayed join work is generation-bound, so leaving,
switching servers, or losing realtime coordination cannot later revive a
screen or system-audio publication. Native two-client screen video/system-audio
validation, wrong/no-key tests, packet inspection, deployment, and independent
review remain incomplete, so this is not yet a verified E2EE claim.

## Product Requirements

Screen sharing is a community-broadcast feature, not a short-call
afterthought:

- There must be no intentional duration cutoff. A stream should be able to run
  for 10 minutes, several hours, or 24+ hours while the network, machine,
  portal session, and server remain available.
- 1080p at 60 FPS is a required quality tier.
- Lower-cost tiers must remain available for weaker computers and connections.
- A selected tier is a ceiling, not a promise to saturate the connection.
  WebRTC congestion control must lower actual bitrate under pressure instead
  of ending the stream.
- Higher source tiers such as 1440p and 4K may be exposed when encoder,
  network, and server testing proves them sustainable.
- Capture queues must remain bounded so a slow encoder drops old frames rather
  than accumulating latency or memory indefinitely.
- Long-running streams need health metrics, recovery from transient transport
  interruptions, and explicit user-visible failure reasons.

## Why the Linux Path Was Rebuilt

The stock `flutter_webrtc` Linux Wayland path used two independent native
desktop capturers:

1. `desktopCapturer.getSources()` created a PipeWire capturer to enumerate a
   source, opening KDE's portal chooser.
2. `getDisplayMedia()` created another capturer for the selected source,
   opening a second KDE chooser.

It also returned a video-track object before the portal produced frames.
Cancellation left source/session state in a condition that often prevented a
new chooser from opening.

Dart-side retries and UI guards could not repair that native ownership model.
Yappa therefore replaced only the Linux Wayland capture adapter while keeping
LiveKit publication, remote playback, and the Windows path.

## Current Architecture

### Dependency foundation

- `flutter_webrtc`: local 1.5.2 fork at
  `client/packages/flutter_webrtc_yappa`.
- `livekit_client`: `2.9.0-dev.0`, the release aligned with
  `flutter_webrtc` 1.5.2.
- The root client uses a `dependency_overrides` path for the local WebRTC fork.
- Linux CMake forces `<cstdint>` into C++ translation units because the
  upstream 1.5.2 libwebrtc headers omit it in a header that uses `uint32_t`.

Do not edit the global Pub cache. All reproducible native changes belong in
the local fork.

### Linux Wayland video flow

Relevant files:

- `client/lib/data/voice_transport_service.dart`
- `client/packages/flutter_webrtc_yappa/common/cpp/include/yappa_portal_capture.h`
- `client/packages/flutter_webrtc_yappa/common/cpp/src/yappa_portal_capture.cc`
- `client/packages/flutter_webrtc_yappa/common/cpp/src/flutter_screen_capture.cc`
- `client/packages/flutter_webrtc_yappa/lib/yappa_portal_capture.dart`

Flow:

1. Yappa passes the reserved source id `yappa-portal`.
2. The local WebRTC fork recognizes that id and bypasses desktop-source
   enumeration.
3. `YappaPortalCapture` creates one
   `org.freedesktop.portal.ScreenCast` session.
4. KDE owns the single source-selection window.
5. Yappa opens the returned PipeWire remote and selected node.
6. GStreamer converts and scales the stream to the selected quality ceiling,
   then rate-limits it to that preset's FPS.
7. Frames are injected into libwebrtc's custom `RTCVideoSource`.
8. LiveKit publishes the resulting ordinary local screen-video track.

The GStreamer pipeline uses a two-frame leaky queue. Old frames are dropped
instead of building latency. The PipeWire file descriptor remains open for the
entire capture session and is closed during explicit teardown.

### Quality ceilings

Screen-share quality is local device state persisted through
`YappaVideoPreferences`. The current presets are:

| Preset | Capture ceiling | Publish ceiling |
| --- | --- | --- |
| Efficient | 1280×720 at 30 FPS | 3 Mbps |
| Balanced | 1920×1080 at 30 FPS | 5 Mbps |
| Smooth (default) | 1920×1080 at 60 FPS | 8 Mbps |
| High | 2560×1440 at 60 FPS | 14 Mbps |

The selected dimensions and frame rate are applied both to native capture and
LiveKit publication. Publication enables simulcast and uses balanced WebRTC
degradation, allowing congestion control and receivers to use a less expensive
representation without treating bandwidth pressure as a reason to stop the
stream. A preset is a maximum, not a guaranteed measured output.

### Capture/UI state

The intended state progression is:

```text
idle -> selecting -> capturing frames -> publishing -> stopped
```

Yappa must not announce or display screen sharing merely because a native
track object exists. It waits until WebRTC sender stats report at least one
sent frame. The local screen-sharing UI additionally requires:

- selection is no longer pending;
- server voice presence says screen sharing is enabled; and
- the local screen-video track exists.

Cancellation is normal, returns to idle, and must permit an immediate retry.
Stopping calls the fork's `stopYappaPortalCapture` method so the GStreamer
pipeline, PipeWire descriptor, portal session, and source are released.

## Backend Voice-State Fix

The server receives partial `voice:state` patches. Before 2026-07-23 it merged
them like this conceptually:

```text
existing state + every possible key, including undefined values
```

Sanitization converted undefined values to `false`. A later `speaking` update
therefore reset `screenShareEnabled`, even though native capture continued.

`server/src/server.js` now uses `mergeVoiceMediaState`, applying only patch
keys whose values are actual booleans. This fix was deployed to Unraid and the
health endpoint was verified.

## Confirmed Test Results

On Nobara KDE Wayland:

- One KDE chooser appears: confirmed.
- Cancelling the chooser and immediately retrying: confirmed.
- Sharing does not appear active before frames flow: confirmed.
- PipeWire descriptor lifetime fix improved stability: confirmed.
- Native 15 FPS diagnostic throttle worked: confirmed by frame logs. Before
  throttling,
  approximately 133 FPS entered WebRTC; afterward frame counts matched 15 FPS.
- The fixed throttle has been replaced in source with user-selected
  capture/publish ceilings, including 1080p60. The new presets compile, but
  their measured frame rate and long-running behavior still require runtime
  validation.
- A 55-second apparent cutoff occurred while PipeWire continued delivering
  frames. This led to the backend partial-state merge fix described above.
- Sustained sharing after the deployed backend fix still requires a new soak
  test.

## Current Diagnostics

Debug builds log:

- the first delivered PipeWire frame and every 300th frame;
- GStreamer errors, warnings, and EOS;
- the first WebRTC sender frame;
- unexpected local LiveKit screen-track unpublishing; and
- client-side clearing of screen-share presence.

Keep these diagnostics until the Linux soak test is consistently successful.
After stabilization, reduce periodic frame logging but retain actionable
errors and lifecycle transitions.

## Desktop Audio Status

The Linux desktop-audio path is implemented and awaiting two-client runtime
validation.

- The native Linux loopback capturer uses GStreamer's `pulsesrc` against
  `@DEFAULT_MONITOR@`. On Nobara this is provided by PipeWire's PulseAudio
  compatibility service.
- Audio is converted to interleaved 48 kHz, 16-bit stereo PCM and fed into a
  custom WebRTC audio source.
- Echo cancellation, automatic gain control, and noise suppression are
  disabled for system audio.
- LiveKit receives it as a distinct `screenShareAudio` track, leaving
  microphone audio independent.
- Explicit portal teardown stops both the video capture and system-audio
  pipeline. If loopback initialization fails, screen video continues and the
  native client logs the audio failure.
- `flutter_webrtc` 1.5.2 also provides the separate Windows WASAPI loopback
  implementation.

Do not call Linux desktop audio confirmed until a second client hears it,
microphone audio remains independent, and repeated start/stop is clean.

## Required Test Matrix

### Nobara KDE Wayland

- Select each physical display.
- Select a window if the portal offers it.
- Cancel, retry, stop, and restart repeatedly.
- Share continuously for 1, 5, and 30 minutes.
- Change mic mute, speaker mute, camera, and speaking state during sharing.
- Disconnect/reconnect LiveKit during sharing.
- Close Yappa while sharing and confirm the portal/PipeWire session disappears.
- Verify CPU, memory, frame rate, latency, and no unbounded queue growth.
- Verify desktop audio from a second client once implemented.

### Linux X11

- Confirm the legacy source picker still selects screens reliably.
- Confirm cancellation and restart.
- Confirm Linux packaging states its runtime GStreamer requirements.

### Windows

- Yappa owns the Windows source picker; Windows does not provide the
  Linux-portal-style chooser used by KDE.
- The picker enumerates both displays and application windows and requests
  320×180 source thumbnails. It always waits for an explicit selection, even
  when only one source is available, and cancellation leaves sharing idle.
- The selected native source id is passed directly to `getDisplayMedia`; Yappa
  then uses the same quality ceiling, LiveKit simulcast, balanced degradation,
  first-frame gate, and explicit teardown path as other desktop platforms.
- The local `flutter_webrtc` fork contains a Windows WASAPI
  `ApplicationLoopbackCapturer`. Display sharing captures system output while
  window sharing attempts to restrict audio to the selected window's process.
  Application loopback requires Windows 10 version 2004/build 19041 or newer.
- The repository's separate `build_windows.yml` workflow invokes the shared
  client validation gate and a locally runnable PowerShell build/package
  script. It verifies the MLS and libsodium DLLs, scans the bundle, and
  smoke-launches the packaged executable before artifact upload. This
  replacement is implemented locally as of 2026-07-28 but still requires a
  successful hosted Windows run. A successful compile and smoke launch do not
  replace hardware capture and playback testing.

- Test monitor and window selection.
- Verify source thumbnails and names for multiple monitors and applications.
- Test cancellation and immediate retry.
- Close the selected window or disconnect the selected monitor while live,
  then verify a clear failure and a clean retry.
- Test continuous sharing for at least 30 minutes.
- Test 1080p60 locally and from a second client, including motion and text.
- Verify desktop/system audio from a second client.
- Verify window sharing does not leak unrelated application audio where
  per-process loopback is supported.
- Verify microphone and desktop audio remain separate tracks.

### Cross-client

- A second client sees sharing only after frames flow.
- Remote playback disappears promptly when capture ends.
- Presence does not reset when speaking, mute, or camera updates occur.
- Reconnect does not leave a ghost share.

## Build Dependencies

The current Nobara development host has:

```text
gstreamer1-devel
gstreamer1-plugins-base-devel
```

The Linux plugin links GStreamer core, app, and video libraries. Packaging must
declare compatible runtime dependencies. The full desktop build additionally
needs Nobara's `webkit2gtk4.1-devel` for the inline link-preview webview. That
package and its development dependencies were installed through the
authenticated system package manager on 2026-07-24; the current Linux debug
and release bundles then built successfully, and the release binary launched.
Bundle inspection confirmed the WebRTC/LiveKit and WebKit plugins with
resolved linked dependencies on the validation host. Build with:

```bash
cd client
flutter pub get
flutter analyze
flutter build linux --debug --no-pub
```

## Next Steps

1. Runtime-validate every quality preset, including measured 1080p60 capture
   and remote playback on a second client.
2. Run a sustained Wayland share while toggling speaking and mute state.
3. Add 10-minute, 1-hour, and overnight/24-hour soak procedures with bounded
   memory, stable latency, and reconnect observations.
4. If capture stops, classify it using the existing diagnostics before making
   another change.
5. Fix shutdown/teardown races; one prior interrupted diagnostic process
   exited with status 139, so native cleanup deserves stress testing.
6. Validate Linux desktop audio from a second client, including repeated
   start/stop and simultaneous microphone capture.
7. Run the Windows CI release build, then validate capture and loopback audio
   on real Windows 10 2004+ and Windows 11 hardware.
8. Reduce debug logging only after the test matrix is stable.
