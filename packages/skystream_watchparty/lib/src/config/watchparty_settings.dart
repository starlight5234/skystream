import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WatchPartySettings extends ChangeNotifier {
  String _watchPartyUsername;
  String _watchPartyProjectId;
  String _watchPartyAnonKey;
  String _watchPartyTurnUsername;
  String _watchPartyTurnPassword;

  WatchPartySettings({
    String watchPartyUsername = '',
    String watchPartyProjectId = '',
    String watchPartyAnonKey = '',
    String watchPartyTurnUsername = '',
    String watchPartyTurnPassword = '',
  })  : _watchPartyUsername = watchPartyUsername,
        _watchPartyProjectId = watchPartyProjectId,
        _watchPartyAnonKey = watchPartyAnonKey,
        _watchPartyTurnUsername = watchPartyTurnUsername,
        _watchPartyTurnPassword = watchPartyTurnPassword;

  static WatchPartySettings fromGeneralSettings(dynamic settings) {
    if (settings == null) return WatchPartySettings();
    try {
      return WatchPartySettings(
        watchPartyUsername: (settings.watchPartyUsername as String?) ?? '',
        watchPartyProjectId: (settings.watchPartyProjectId as String?) ?? '',
        watchPartyAnonKey: (settings.watchPartyAnonKey as String?) ?? '',
        watchPartyTurnUsername: (settings.watchPartyTurnUsername as String?) ?? '',
        watchPartyTurnPassword: (settings.watchPartyTurnPassword as String?) ?? '',
      );
    } catch (_) {
      return WatchPartySettings();
    }
  }

  String get watchPartyUsername => _watchPartyUsername;
  String get watchPartyProjectId => _watchPartyProjectId;
  String get watchPartyAnonKey => _watchPartyAnonKey;
  String get watchPartyTurnUsername => _watchPartyTurnUsername;
  String get watchPartyTurnPassword => _watchPartyTurnPassword;

  static Future<WatchPartySettings> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    return WatchPartySettings(
      watchPartyUsername: prefs.getString('watchPartyUsername') ?? '',
      watchPartyProjectId: prefs.getString('watchPartyProjectId') ?? '',
      watchPartyAnonKey: prefs.getString('watchPartyAnonKey') ?? '',
      watchPartyTurnUsername: prefs.getString('watchPartyTurnUsername') ?? '',
      watchPartyTurnPassword: prefs.getString('watchPartyTurnPassword') ?? '',
    );
  }

  Future<void> update({
    String? username,
    String? projectId,
    String? anonKey,
    String? turnUsername,
    String? turnPassword,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (username != null) {
      _watchPartyUsername = username;
      await prefs.setString('watchPartyUsername', username);
    }
    if (projectId != null) {
      _watchPartyProjectId = projectId;
      await prefs.setString('watchPartyProjectId', projectId);
    }
    if (anonKey != null) {
      _watchPartyAnonKey = anonKey;
      await prefs.setString('watchPartyAnonKey', anonKey);
    }
    if (turnUsername != null) {
      _watchPartyTurnUsername = turnUsername;
      await prefs.setString('watchPartyTurnUsername', turnUsername);
    }
    if (turnPassword != null) {
      _watchPartyTurnPassword = turnPassword;
      await prefs.setString('watchPartyTurnPassword', turnPassword);
    }
    notifyListeners();
  }
}
