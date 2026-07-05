import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'storage_service.dart';

part 'settings_repository.g.dart';

@Riverpod(keepAlive: true)
SettingsRepository settingsRepository(Ref ref) {
  return SettingsRepository(ref.watch(storageServiceProvider));
}

class SettingsRepository {
  final StorageService _storageService;

  SettingsRepository(this._storageService);

  Future<void> saveThemeMode(String mode) async {
    await _storageService.saveThemeMode(mode);
  }

  String? getThemeMode() {
    return _storageService.getThemeMode();
  }

  Future<void> setSidebarExpanded(bool expanded) async {
    await _storageService.setSidebarExpanded(expanded);
  }

  bool? getSidebarExpanded() {
    return _storageService.getSidebarExpanded();
  }

  Future<void> setDefaultHomeScreen(String path) async {
    await _storageService.setDefaultHomeScreen(path);
  }

  String getDefaultHomeScreen() {
    return _storageService.getDefaultHomeScreen();
  }

  Future<void> setDevLoadAssets(bool enabled) async {
    await _storageService.setDevLoadAssets(enabled);
  }

  bool getDevLoadAssets() {
    return _storageService.getDevLoadAssets();
  }

  Future<void> setWatchPartyDebugEnabled(bool enabled) async {
    await _storageService.setWatchPartyDebugEnabled(enabled);
  }

  bool getWatchPartyDebugEnabled() {
    return _storageService.getWatchPartyDebugEnabled();
  }

  Future<void> setActiveProviderId(String? id) =>
      _storageService.setActiveProviderId(id);

  String? getActiveProviderId() {
    return _storageService.getActiveProviderId();
  }

  Future<void> setCustomBaseUrl(String packageName, String? url) =>
      _storageService.setCustomBaseUrl(packageName, url);

  String? getCustomBaseUrl(String packageName) =>
      _storageService.getCustomBaseUrl(packageName);

  Future<void> setLanguage(String lang) async {
    await _storageService.setLanguage(lang);
  }

  String getLanguage() {
    return _storageService.getLanguage();
  }

  Future<void> setExploreLanguage(String lang) async {
    await _storageService.setExploreLanguage(lang);
  }

  String getExploreLanguage() {
    return _storageService.getExploreLanguage();
  }

  Future<void> setWatchHistoryEnabled(bool enabled) async {
    await _storageService.setWatchHistoryEnabled(enabled);
  }

  bool isWatchHistoryEnabled() {
    return _storageService.isWatchHistoryEnabled();
  }

  Future<void> setGithubProxyEnabled(bool enabled) async {
    await _storageService.setGithubProxyEnabled(enabled);
  }

  bool isGithubProxyEnabled() {
    return _storageService.isGithubProxyEnabled();
  }

  Future<void> setIntroDbIntegrationEnabled(bool enabled) async {
    await _storageService.setIntroDbIntegrationEnabled(enabled);
  }

  bool isIntroDbIntegrationEnabled() {
    return _storageService.isIntroDbIntegrationEnabled();
  }

  Future<void> setAnimeSkipIntegrationEnabled(bool enabled) async {
    await _storageService.setAnimeSkipIntegrationEnabled(enabled);
  }

  bool isAnimeSkipIntegrationEnabled() {
    return _storageService.isAnimeSkipIntegrationEnabled();
  }

  Future<void> setPlayerSetting(String key, dynamic value) async {
    await _storageService.setPlayerSetting(key, value);
  }

  T? getPlayerSetting<T>(String key, {T? defaultValue}) {
    return _storageService.getPlayerSetting<T>(key, defaultValue: defaultValue);
  }

  Future<void> setWatchPartyProjectId(String? id) =>
      _storageService.setString('watchparty_supabase_project_id', id);

  String? getWatchPartyProjectId() =>
      _storageService.getString('watchparty_supabase_project_id');

  Future<void> setWatchPartyAnonKey(String? key) =>
      _storageService.setString('watchparty_supabase_anon_key', key);

  String? getWatchPartyAnonKey() =>
      _storageService.getString('watchparty_supabase_anon_key');

  Future<void> setWatchPartyUsername(String name) =>
      _storageService.setString('watchparty_username', name);

  String? getWatchPartyUsername() =>
      _storageService.getString('watchparty_username');

  Future<void> setWatchPartyTurnUsername(String? username) =>
      _storageService.setString('watchparty_turn_username', username);

  String? getWatchPartyTurnUsername() =>
      _storageService.getString('watchparty_turn_username');

  Future<void> setWatchPartyTurnPassword(String? password) =>
      _storageService.setString('watchparty_turn_password', password);

  String? getWatchPartyTurnPassword() =>
      _storageService.getString('watchparty_turn_password');

  Future<void> clearPreferences({bool keepRepos = true}) async {
    await _storageService.clearPreferences(keepRepos: keepRepos);
  }

  Future<void> deleteAllData() async {
    await _storageService.deleteAllData();
  }
}
