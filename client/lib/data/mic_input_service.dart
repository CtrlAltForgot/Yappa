import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'audio_preferences.dart';

class MicInputSnapshot {
  final bool hasPermission;
  final bool isCapturing;
  final double level;
  final double peak;
  final String? error;

  const MicInputSnapshot({
    required this.hasPermission,
    required this.isCapturing,
    required this.level,
    required this.peak,
    this.error,
  });

  const MicInputSnapshot.idle()
      : hasPermission = false,
        isCapturing = false,
        level = 0,
        peak = 0,
        error = null;

  MicInputSnapshot copyWith({
    bool? hasPermission,
    bool? isCapturing,
    double? level,
    double? peak,
    String? error,
    bool clearError = false,
  }) {
    return MicInputSnapshot(
      hasPermission: hasPermission ?? this.hasPermission,
      isCapturing: isCapturing ?? this.isCapturing,
      level: level ?? this.level,
      peak: peak ?? this.peak,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class MicInputService extends ChangeNotifier {
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<Uint8List>? _audioStreamSubscription;
  Timer? _peakDecayTimer;

  MicInputSnapshot _snapshot = const MicInputSnapshot.idle();

  MicInputSnapshot get snapshot => _snapshot;
  bool get hasPermission => _snapshot.hasPermission;
  bool get isCapturing => _snapshot.isCapturing;
  double get level => _snapshot.level;
  double get peak => _snapshot.peak;
  String? get error => _snapshot.error;

  Future<bool> ensurePermission() async {
    try {
      final granted = await _recorder.hasPermission();
      _updateSnapshot(
        _snapshot.copyWith(
          hasPermission: granted,
          clearError: granted,
          error: granted ? null : 'Microphone permission was denied.',
        ),
      );
      return granted;
    } catch (e) {
      _updateSnapshot(
        _snapshot.copyWith(
          hasPermission: false,
          error: 'Could not check microphone permission: $e',
        ),
      );
      return false;
    }
  }

  Future<void> startCapture() async {
    if (_snapshot.isCapturing) return;

    await YappaAudioPreferences.load();

    final granted = await ensurePermission();
    if (!granted) return;

    try {
      final config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 48000,
        numChannels: 1,
        bitRate: 128000,
        autoGain: YappaAudioPreferences.autoGainControl,
        echoCancel: YappaAudioPreferences.echoCancellation,
        noiseSuppress: YappaAudioPreferences.noiseSuppression,
      );

      final stream = await _recorder.startStream(config);

      _audioStreamSubscription?.cancel();
      _audioStreamSubscription = stream.listen(
        (_) {},
        onError: (Object e, StackTrace stackTrace) {
          _updateSnapshot(
            _snapshot.copyWith(
              error: 'Microphone stream error: $e',
            ),
          );
        },
        cancelOnError: false,
      );

      _amplitudeSubscription?.cancel();
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 70))
          .listen(_handleAmplitude);

      _peakDecayTimer?.cancel();
      _peakDecayTimer = Timer.periodic(
        const Duration(milliseconds: 90),
        (_) => _decayPeak(),
      );

      _updateSnapshot(
        _snapshot.copyWith(
          hasPermission: true,
          isCapturing: true,
          level: 0,
          peak: 0,
          clearError: true,
        ),
      );
    } catch (e) {
      _updateSnapshot(
        _snapshot.copyWith(
          isCapturing: false,
          level: 0,
          peak: 0,
          error: 'Could not start microphone capture: $e',
        ),
      );
    }
  }

  Future<void> restartCaptureIfRunning() async {
    if (!_snapshot.isCapturing) return;
    await stopCapture();
    await startCapture();
  }

  Future<void> stopCapture() async {
    _peakDecayTimer?.cancel();
    _peakDecayTimer = null;

    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    _updateSnapshot(
      _snapshot.copyWith(
        isCapturing: false,
        level: 0,
        peak: 0,
      ),
    );
  }

  void _handleAmplitude(Amplitude amplitude) {
    final rawLevel = _normalizeDb(amplitude.current);
    final processedLevel = _processLevel(rawLevel);
    final nextPeak =
        processedLevel > _snapshot.peak ? processedLevel : _snapshot.peak;

    _updateSnapshot(
      _snapshot.copyWith(
        level: processedLevel,
        peak: nextPeak,
        clearError: true,
      ),
    );
  }

  double _processLevel(double rawLevel) {
    return (rawLevel * YappaAudioPreferences.inputGain).clamp(0.0, 1.0);
  }

  void _decayPeak() {
    if (!_snapshot.isCapturing) return;

    final decayed = (_snapshot.peak - 0.035).clamp(0.0, 1.0);
    if ((decayed - _snapshot.peak).abs() < 0.0001) return;

    _updateSnapshot(
      _snapshot.copyWith(peak: decayed),
    );
  }

  double _normalizeDb(double db) {
    if (db.isNaN || db.isInfinite) return 0;
    if (db <= -60) return 0;
    if (db >= 0) return 1;

    final normalized = (db + 60) / 60;
    return normalized.clamp(0.0, 1.0);
  }

  void _updateSnapshot(MicInputSnapshot next) {
    _snapshot = next;
    notifyListeners();
  }

  @override
  void dispose() {
    stopCapture();
    _recorder.dispose();
    super.dispose();
  }
}