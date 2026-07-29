import 'dart:async';
import 'dart:math';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:skystream_watchparty/skystream_watchparty.dart';
import '../../../core/storage/settings_repository.dart';

part 'general_settings_provider.g.dart';

class GeneralSettings {
  final bool watchHistoryEnabled;
  final String defaultHomeScreen;
  final bool githubProxyEnabled;
  final WatchPartySettings watchParty;

  const GeneralSettings({
    this.watchHistoryEnabled = true,
    this.defaultHomeScreen = '/home',
    this.githubProxyEnabled = false,
    this.watchParty = const WatchPartySettings(),
  });

  // Convenience getters pointing directly to the unified WatchPartySettings
  String get watchPartyProjectId => watchParty.projectId;
  String get watchPartyAnonKey => watchParty.anonKey;
  String get watchPartyUsername => watchParty.username;
  String get watchPartyTurnUsername => watchParty.turnUsername;
  String get watchPartyTurnPassword => watchParty.turnPassword;
  bool get watchPartyDebugEnabled => watchParty.debugEnabled;

  GeneralSettings copyWith({
    bool? watchHistoryEnabled,
    String? defaultHomeScreen,
    bool? githubProxyEnabled,
    WatchPartySettings? watchParty,
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
      watchParty: watchParty ??
          (this.watchParty.copyWith(
                projectId: watchPartyProjectId,
                anonKey: watchPartyAnonKey,
                username: watchPartyUsername,
                turnUsername: watchPartyTurnUsername,
                turnPassword: watchPartyTurnPassword,
                debugEnabled: watchPartyDebugEnabled,
              )),
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

    final wpSettings = WatchPartySettings(
      projectId: (localId != null && localId.trim().isNotEmpty)
          ? localId
          : const String.fromEnvironment('SUPABASE_PROJECT_ID'),
      anonKey: (localKey != null && localKey.trim().isNotEmpty)
          ? localKey
          : const String.fromEnvironment('SUPABASE_ANON_KEY'),
      username: watchPartyUsername,
      turnUsername: (localTurnUser != null && localTurnUser.trim().isNotEmpty)
          ? localTurnUser
          : const String.fromEnvironment('TURN_USERNAME'),
      turnPassword: (localTurnPass != null && localTurnPass.trim().isNotEmpty)
          ? localTurnPass
          : const String.fromEnvironment('TURN_PASSWORD'),
      debugEnabled: repository.getWatchPartyDebugEnabled(),
    );

    return GeneralSettings(
      watchHistoryEnabled: repository.isWatchHistoryEnabled(),
      defaultHomeScreen: repository.getDefaultHomeScreen(),
      githubProxyEnabled: repository.isGithubProxyEnabled(),
      watchParty: wpSettings,
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
    state = state.copyWith(watchParty: state.watchParty.copyWith(projectId: id));
  }

  Future<void> setWatchPartyAnonKey(String key) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyAnonKey(key);
    state = state.copyWith(watchParty: state.watchParty.copyWith(anonKey: key));
  }

  Future<void> setWatchPartyUsername(String name) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyUsername(name);
    state = state.copyWith(watchParty: state.watchParty.copyWith(username: name));
  }

  Future<void> setWatchPartyTurnUsername(String username) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyTurnUsername(username);
    state = state.copyWith(watchParty: state.watchParty.copyWith(turnUsername: username));
  }

  Future<void> setWatchPartyTurnPassword(String password) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyTurnPassword(password);
    state = state.copyWith(watchParty: state.watchParty.copyWith(turnPassword: password));
  }

  Future<void> setWatchPartyDebugEnabled(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchPartyDebugEnabled(enabled);
    state = state.copyWith(watchParty: state.watchParty.copyWith(debugEnabled: enabled));
  }
}
