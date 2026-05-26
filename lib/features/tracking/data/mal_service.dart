import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'tracking_service.dart';
import '../domain/sync_progress_item.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/config/sync_config.dart';

part 'mal_service.g.dart';

class MalService implements TrackingService {
  final Dio _dio;
  final StorageService _storage;
  
  static const String _clientId = SyncConfig.malClientId;
  
  String? _accessToken;

  MalService(this._dio, this._storage) {
    _initToken();
  }

  void _initToken() {
    _accessToken = _storage.getString('mal_access_token');
  }

  @override
  String get name => 'MyAnimeList';

  @override
  String get idPrefix => 'mal';

  @override
  String get mainUrl => 'https://myanimelist.net';

  @override
  Future<bool> get isLoggedIn async => _accessToken != null;

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    try {
      talker.debug('MALService: Initiating OAuth Flow...');

      const authUrl = 'https://myanimelist.net/v1/oauth2/authorize'
          '?response_type=code'
          '&client_id=$_clientId'
          '&code_challenge=skystream_challenge';

      talker.debug('MYANIMELIST LOGIN — open in browser/webview: $authUrl');

      if (onWebViewRequested != null) {
        await onWebViewRequested(authUrl);
      }
      return true;
    } catch (e) {
      talker.error('MALService: Login error', e);
      return false;
    }
  }

  @override
  Future<void> logout() async {
    talker.debug('MALService: Logging out...');
    _accessToken = null;
    await _storage.remove('mal_access_token');
  }

  @override
  Future<List<MultimediaItem>> search(String query) async {
    if (_accessToken == null) return [];
    
    // Search implementation
    return [];
  }

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async {
    // MAL API doesn't have a direct reverse lookup from IMDB/TMDB
    // We rely on Simkl or MAL-Sync database to resolve MAL IDs
    return {};
  }

  Future<bool> _updateListStatus(int malId, {String? status, int? numWatchedEpisodes}) async {
    try {
      final data = <String, dynamic>{};
      if (status != null) data['status'] = status;
      if (numWatchedEpisodes != null) data['num_watched_episodes'] = numWatchedEpisodes;

      final response = await _dio.patch<dynamic>(
        'https://api.myanimelist.net/v2/anime/$malId/my_list_status',
        data: data,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );

      talker.debug('MALService: Update list status success: ${response.statusCode}');
      return response.statusCode == 200;
    } catch (e) {
      talker.error('MALService: Update list status failed', e);
      return false;
    }
  }

  @override
  Future<bool> markWatched(MultimediaItem item, Episode? episode, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    final malIdStr = resolvedIds?['mal'];
    if (malIdStr == null) return false;
    
    final malId = int.tryParse(malIdStr);
    if (malId == null) return false;

    if (item.contentType == MultimediaContentType.movie) {
      return _updateListStatus(malId, status: 'completed');
    } else {
      if (episode == null) return false;
      return _updateListStatus(malId, numWatchedEpisodes: episode.episode);
    }
  }

  @override
  Future<bool> scrobbleStart(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    final malIdStr = resolvedIds?['mal'];
    if (malIdStr == null) return false;
    
    final malId = int.tryParse(malIdStr);
    if (malId == null) return false;

    // Set status to watching
    return _updateListStatus(malId, status: 'watching');
  }

  @override
  Future<bool> scrobblePause(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    // No-op for MAL
    return true;
  }

  @override
  Future<bool> scrobbleStop(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    // No-op for MAL
    return true;
  }

  @override
  Future<bool> addToPlanToWatch(MultimediaItem item, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    final malIdStr = resolvedIds?['mal'];
    if (malIdStr == null) return false;
    
    final malId = int.tryParse(malIdStr);
    if (malId == null) return false;

    return _updateListStatus(malId, status: 'plan_to_watch');
  }
  @override
  Future<List<SyncProgressItem>> pullPlaybackProgress() async {
    return [];
  }

  @override
  Future<bool> removePlaybackProgress(String id) async {
    return false;
  }
}

@riverpod
MalService malService(Ref ref) {
  return MalService(
    ref.watch(dioClientProvider),
    ref.watch(storageServiceProvider),
  );
}
