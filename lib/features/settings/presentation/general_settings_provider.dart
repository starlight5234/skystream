import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/storage/settings_repository.dart';

part 'general_settings_provider.g.dart';

class GeneralSettings {
  final bool watchHistoryEnabled;
  final String defaultHomeScreen;
  final bool githubProxyEnabled;

  const GeneralSettings({
    this.watchHistoryEnabled = true,
    this.defaultHomeScreen = '/home',
    this.githubProxyEnabled = false,
  });

  GeneralSettings copyWith({
    bool? watchHistoryEnabled,
    String? defaultHomeScreen,
    bool? githubProxyEnabled,
  }) {
    return GeneralSettings(
      watchHistoryEnabled: watchHistoryEnabled ?? this.watchHistoryEnabled,
      defaultHomeScreen: defaultHomeScreen ?? this.defaultHomeScreen,
      githubProxyEnabled: githubProxyEnabled ?? this.githubProxyEnabled,
    );
  }
}

@Riverpod(keepAlive: true)
class GeneralSettingsNotifier extends _$GeneralSettingsNotifier {
  @override
  GeneralSettings build() {
    final repository = ref.watch(settingsRepositoryProvider);
    return GeneralSettings(
      watchHistoryEnabled: repository.isWatchHistoryEnabled(),
      defaultHomeScreen: repository.getDefaultHomeScreen(),
      githubProxyEnabled: repository.isGithubProxyEnabled(),
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
}
