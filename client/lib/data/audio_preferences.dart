import 'package:shared_preferences/shared_preferences.dart';

enum YappaVoiceInputMode {
  pushToTalk,
  alwaysOn,
  voiceActivityDetection,
}

class YappaAudioPreferences {
  static const _preferredInputDeviceIdKey =
      'yappa_audio_preferred_input_device_id';
  static const _preferredOutputDeviceIdKey =
      'yappa_audio_preferred_output_device_id';
  static const _voiceInputModeKey = 'yappa_audio_voice_input_mode';
  static const _pushToTalkKeyLabelKey = 'yappa_audio_push_to_talk_key_label';
  static const _inputGainKey = 'yappa_audio_input_gain';
  static const _automaticSensitivityKey =
      'yappa_audio_automatic_sensitivity';
  static const _manualSensitivityKey = 'yappa_audio_manual_sensitivity';
  static const _echoCancellationKey = 'yappa_audio_echo_cancellation';
  static const _noiseSuppressionKey = 'yappa_audio_noise_suppression';
  static const _autoGainControlKey = 'yappa_audio_auto_gain_control';

  static bool _loaded = false;

  static String? preferredInputDeviceId;
  static String? preferredOutputDeviceId;
  static YappaVoiceInputMode voiceInputMode =
      YappaVoiceInputMode.voiceActivityDetection;
  static String pushToTalkKeyLabel = 'Mouse 4';
  static double inputGain = 1.0;
  static bool automaticSensitivity = false;
  static double manualSensitivity = 0.12;
  static bool echoCancellation = true;
  static bool noiseSuppression = true;
  static bool autoGainControl = true;

  static Future<void> load() async {
    if (_loaded) return;

    final prefs = await SharedPreferences.getInstance();

    preferredInputDeviceId = prefs.getString(_preferredInputDeviceIdKey);
    preferredOutputDeviceId = prefs.getString(_preferredOutputDeviceIdKey);

    final savedMode = prefs.getString(_voiceInputModeKey);
    voiceInputMode = YappaVoiceInputMode.values.firstWhere(
      (value) => value.name == savedMode,
      orElse: () => YappaVoiceInputMode.voiceActivityDetection,
    );

    pushToTalkKeyLabel =
        prefs.getString(_pushToTalkKeyLabelKey)?.trim().isNotEmpty == true
            ? prefs.getString(_pushToTalkKeyLabelKey)!.trim()
            : 'Mouse 4';

    inputGain = (prefs.getDouble(_inputGainKey) ?? 1.0).clamp(0.5, 3.0);
    automaticSensitivity = prefs.getBool(_automaticSensitivityKey) ?? false;
    manualSensitivity =
        (prefs.getDouble(_manualSensitivityKey) ?? 0.12).clamp(0.0, 0.95);
    echoCancellation = prefs.getBool(_echoCancellationKey) ?? true;
    noiseSuppression = prefs.getBool(_noiseSuppressionKey) ?? true;
    autoGainControl = prefs.getBool(_autoGainControlKey) ?? true;

    _loaded = true;
  }

  static Future<void> setPreferredInputDeviceId(String? value) async {
    await load();

    preferredInputDeviceId =
        (value == null || value.trim().isEmpty) ? null : value.trim();

    final prefs = await SharedPreferences.getInstance();
    if (preferredInputDeviceId == null) {
      await prefs.remove(_preferredInputDeviceIdKey);
    } else {
      await prefs.setString(
        _preferredInputDeviceIdKey,
        preferredInputDeviceId!,
      );
    }
  }

  static Future<void> setPreferredOutputDeviceId(String? value) async {
    await load();

    preferredOutputDeviceId =
        (value == null || value.trim().isEmpty) ? null : value.trim();

    final prefs = await SharedPreferences.getInstance();
    if (preferredOutputDeviceId == null) {
      await prefs.remove(_preferredOutputDeviceIdKey);
    } else {
      await prefs.setString(
        _preferredOutputDeviceIdKey,
        preferredOutputDeviceId!,
      );
    }
  }

  static Future<void> setVoiceInputMode(YappaVoiceInputMode value) async {
    await load();
    voiceInputMode = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_voiceInputModeKey, value.name);
  }

  static Future<void> setPushToTalkKeyLabel(String value) async {
    await load();
    final cleaned = value.trim();
    if (cleaned.isEmpty) return;

    pushToTalkKeyLabel = cleaned;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pushToTalkKeyLabelKey, pushToTalkKeyLabel);
  }

  static Future<void> setInputGain(double value) async {
    await load();
    inputGain = value.clamp(0.5, 3.0);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_inputGainKey, inputGain);
  }

  static Future<void> setAutomaticSensitivity(bool value) async {
    await load();
    automaticSensitivity = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_automaticSensitivityKey, automaticSensitivity);
  }

  static Future<void> setManualSensitivity(double value) async {
    await load();
    manualSensitivity = value.clamp(0.0, 0.95);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_manualSensitivityKey, manualSensitivity);
  }

  static Future<void> setEchoCancellation(bool value) async {
    await load();
    echoCancellation = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_echoCancellationKey, value);
  }

  static Future<void> setNoiseSuppression(bool value) async {
    await load();
    noiseSuppression = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_noiseSuppressionKey, value);
  }

  static Future<void> setAutoGainControl(bool value) async {
    await load();
    autoGainControl = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoGainControlKey, value);
  }
}