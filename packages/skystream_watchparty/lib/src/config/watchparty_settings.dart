import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class WatchPartySettings {
  final String username;
  final String projectId;
  final String anonKey;
  final String turnUsername;
  final String turnPassword;
  final bool debugEnabled;
  final bool waitForMembersDefault;

  const WatchPartySettings({
    this.username = '',
    this.projectId = '',
    this.anonKey = '',
    this.turnUsername = '',
    this.turnPassword = '',
    this.debugEnabled = false,
    this.waitForMembersDefault = true,
  });

  bool get isConfigured => projectId.trim().isNotEmpty && anonKey.trim().isNotEmpty;

  WatchPartySettings copyWith({
    String? username,
    String? projectId,
    String? anonKey,
    String? turnUsername,
    String? turnPassword,
    bool? debugEnabled,
    bool? waitForMembersDefault,
  }) {
    return WatchPartySettings(
      username: username ?? this.username,
      projectId: projectId ?? this.projectId,
      anonKey: anonKey ?? this.anonKey,
      turnUsername: turnUsername ?? this.turnUsername,
      turnPassword: turnPassword ?? this.turnPassword,
      debugEnabled: debugEnabled ?? this.debugEnabled,
      waitForMembersDefault: waitForMembersDefault ?? this.waitForMembersDefault,
    );
  }

  Future<WatchPartySettings> update({
    String? username,
    String? projectId,
    String? anonKey,
    String? turnUsername,
    String? turnPassword,
    bool? debugEnabled,
    bool? waitForMembersDefault,
  }) async {
    final updated = copyWith(
      username: username,
      projectId: projectId,
      anonKey: anonKey,
      turnUsername: turnUsername,
      turnPassword: turnPassword,
      debugEnabled: debugEnabled,
      waitForMembersDefault: waitForMembersDefault,
    );
    await updated.saveToPrefs();
    return updated;
  }

  // Aliases for core app property compatibility
  String get watchPartyUsername => username;
  String get watchPartyProjectId => projectId;
  String get watchPartyAnonKey => anonKey;
  String get watchPartyTurnUsername => turnUsername;
  String get watchPartyTurnPassword => turnPassword;
  bool get watchPartyDebugEnabled => debugEnabled;

  static Future<WatchPartySettings> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    return WatchPartySettings(
      username: prefs.getString('watchparty_username') ?? prefs.getString('watchPartyUsername') ?? '',
      projectId: prefs.getString('watchparty_project_id') ?? prefs.getString('watchparty_supabase_project_id') ?? prefs.getString('watchPartyProjectId') ?? '',
      anonKey: prefs.getString('watchparty_anon_key') ?? prefs.getString('watchparty_supabase_anon_key') ?? prefs.getString('watchPartyAnonKey') ?? '',
      turnUsername: prefs.getString('watchparty_turn_username') ?? prefs.getString('watchPartyTurnUsername') ?? '',
      turnPassword: prefs.getString('watchparty_turn_password') ?? prefs.getString('watchPartyTurnPassword') ?? '',
      debugEnabled: prefs.getBool('watchparty_debug_enabled') ?? prefs.getBool('watchparty_debug_logs') ?? false,
      waitForMembersDefault: prefs.getBool('watchparty_wait_for_members') ?? true,
    );
  }

  Future<void> saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('watchparty_username', username);
    await prefs.setString('watchparty_project_id', projectId);
    await prefs.setString('watchparty_anon_key', anonKey);
    await prefs.setString('watchparty_turn_username', turnUsername);
    await prefs.setString('watchparty_turn_password', turnPassword);
    await prefs.setBool('watchparty_debug_enabled', debugEnabled);
    await prefs.setBool('watchparty_wait_for_members', waitForMembersDefault);
  }
}
