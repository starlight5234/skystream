import 'dart:async';
import 'dart:math';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/storage/settings_repository.dart';

part 'general_settings_provider.g.dart';

class GeneralSettings {
  final bool watchHistoryEnabled;
  final String defaultHomeScreen;
  final bool githubProxyEnabled;
  final String watchPartyProjectId;
  final String watchPartyAnonKey;
  final String watchPartyUsername;
  final String watchPartyTurnUsername;
  final String watchPartyTurnPassword;
  final bool watchPartyDebugEnabled;

  const GeneralSettings({
    this.watchHistoryEnabled = true,
    this.defaultHomeScreen = '/home',
    this.githubProxyEnabled = false,
    this.watchPartyProjectId = '',
    this.watchPartyAnonKey = '',
    this.watchPartyUsername = '',
    this.watchPartyTurnUsername = '',
    this.watchPartyTurnPassword = '',
    this.watchPartyDebugEnabled = false,
  });

  GeneralSettings copyWith({
    bool? watchHistoryEnabled,
    String? defaultHomeScreen,
    bool? githubProxyEnabled,
    String? watchPartyProjectId,
    String? watchPartyAnonKey,
    String? watchPartyUsername,
    String? watchPartyTurnUsername,
    String? watchPartyTurnPassword,
    bool? watchPartyDebugEnabled,
  }) {
    return GeneralSettings(
      watchHistoryEnabled: watchHistoryEnabled ?? this.watchHistoryEnabled,
      defaultHomeScreen: defaultHomeScreen ?? this.defaultHomeScreen,
      githubProxyEnabled: githubProxyEnabled ?? this.githubProxyEnabled,
      watchPartyProjectId: watchPartyProjectId ?? this.watchPartyProjectId,
      watchPartyAnonKey: watchPartyAnonKey ?? this.watchPartyAnonKey,
      watchPartyUsername: watchPartyUsername ?? this.watchPartyUsername,
      watchPartyTurnUsername: watchPartyTurnUsername ?? this.watchPartyTurnUsername,
      watchPartyTurnPassword: watchPartyTurnPassword ?? this.watchPartyTurnPassword,
      watchPartyDebugEnabled: watchPartyDebugEnabled ?? this.watchPartyDebugEnabled,
    );
  }
}

@Riverpod(keepAlive: true)
class GeneralSettingsNotifier extends _$GeneralSettingsNotifier {
  @override
  GeneralSettings build() {
    final repository = ref.watch(settingsRepositoryProvider);
    
    final localId = repository.getWatchPartyProjectId();
    final localKey = repository.getWatchPartyAnonKey();
    final localTurnUser = repository.getWatchPartyTurnUsername();
    final localTurnPass = repository.getWatchPartyTurnPassword();

    final savedUsername = repository.getWatchPartyUsername();
    final String watchPartyUsername;
    if (savedUsername == null || savedUsername.trim().isEmpty) {
      final rand = Random().nextInt(9000) + 1000;
      watchPartyUsername = 'User_$rand';
      scheduleMicrotask(() async {
        await repository.setWatchPartyUsername(watchPartyUsername);
      });
    } else {
      watchPartyUsername = savedUsername;
    }

    return GeneralSettings(
      watchHistoryEnabled: repository.isWatchHistoryEnabled(),
      defaultHomeScreen: repository.getDefaultHomeScreen(),
      githubProxyEnabled: repository.isGithubProxyEnabled(),
      watchPartyProjectId: (localId != null && localId.trim().isNotEmpty)
          ? localId
          : const String.fromEnvironment('SUPABASE_PROJECT_ID'),
      watchPartyAnonKey: (localKey != null && localKey.trim().isNotEmpty)
          ? localKey
          : const String.fromEnvironment('SUPABASE_ANON_KEY'),
      watchPartyUsername: watchPartyUsername,
      watchPartyTurnUsername: (localTurnUser != null && localTurnUser.trim().isNotEmpty)
          ? localTurnUser
          : const String.fromEnvironment('TURN_USERNAME'),
      watchPartyTurnPassword: (localTurnPass != null && localTurnPass.trim().isNotEmpty)
          ? localTurnPass
          : const String.fromEnvironment('TURN_PASSWORD'),
      watchPartyDebugEnabled: repository.getWatchPartyDebugEnabled(),
    );
  }

  Future<void> setWatchHistoryEnabled(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchHistoryEnabled(enabled);
    state = state.copyWith(watchHistoryEnabled: enabled);
  }

  Future<void> setDefaultHomeScreen(String path) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setDefaultHomeScreen(path);
    state = state.copyWith(defaultHomeScreen: path);
  }

  Future<void> setGithubProxyEnabled(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setGithubProxyEnabled(enabled);
    state = state.copyWith(githubProxyEnabled: enabled);
  }

  Future<void> setWatchPartyProjectId(String id) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyProjectId(id);
    state = state.copyWith(watchPartyProjectId: id);
  }

  Future<void> setWatchPartyAnonKey(String key) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyAnonKey(key);
    state = state.copyWith(watchPartyAnonKey: key);
  }

  Future<void> setWatchPartyUsername(String name) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyUsername(name);
    state = state.copyWith(watchPartyUsername: name);
  }

  Future<void> setWatchPartyTurnUsername(String username) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyTurnUsername(username);
    state = state.copyWith(watchPartyTurnUsername: username);
  }

  Future<void> setWatchPartyTurnPassword(String password) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyTurnPassword(password);
    state = state.copyWith(watchPartyTurnPassword: password);
  }

  Future<void> setWatchPartyDebugEnabled(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyDebugEnabled(enabled);
    state = state.copyWith(watchPartyDebugEnabled: enabled);
  }
}
