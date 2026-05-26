import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'tracking_service.dart';
import '../domain/sync_progress_item.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/config/sync_config.dart';

part 'simkl_service.g.dart';

class SimklService implements TrackingService {
  final Dio _dio;
  final StorageService _storage;
  
  static const String _clientId = SyncConfig.simklClientId;
  
  String? _accessToken;

  SimklService(this._dio, this._storage) {
    _initToken();
  }

  void _initToken() {
    _accessToken = _storage.getString('simkl_access_token');
  }

  @override
  String get name => 'Simkl';

  @override
  String get idPrefix => 'simkl';

  @override
  String get mainUrl => 'https://simkl.com';

  @override
  Future<bool> get isLoggedIn async => _accessToken != null;

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    try {
      talker.debug('SimklService: Initiating Device PIN Flow...');
      final response = await _dio.get<dynamic>(
        'https://api.simkl.com/oauth/pin',
        queryParameters: {'client_id': _clientId},
      );

      final userCode = response.data['user_code'] as String;
      final verificationUrl = response.data['verification_url'] as String;
      final interval = (response.data['interval'] as num?)?.toInt() ?? 5;

      talker.debug(
        'SIMKL DEVICE LOGIN — go to $verificationUrl and enter code $userCode',
      );

      if (onDeviceCodeGenerated != null) {
        await onDeviceCodeGenerated(verificationUrl, userCode);
      }

      // Polling
      int attempts = 0;
      while (attempts < 60) { // Timeout after ~5 mins (assuming 5s interval)
        if (isCancelled != null && isCancelled()) {
          talker.debug('SimklService: Polling cancelled by user.');
          return false;
        }
        await Future<void>.delayed(Duration(seconds: interval));
        if (isCancelled != null && isCancelled()) return false;

        try {
          talker.debug('SimklService: Polling for token...');
          final tokenResponse = await _dio.get<dynamic>(
            'https://api.simkl.com/oauth/pin/$userCode',
            queryParameters: {'client_id': _clientId},
          );

          final data = tokenResponse.data;
          if (data is Map && data['result'] == 'OK' && data['access_token'] != null) {
            _accessToken = data['access_token'].toString();
            await _storage.setString('simkl_access_token', _accessToken!);
            talker.debug('SimklService: Login successful!');
            return true;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode != 400) {
            talker.debug('SimklService: Polling error: ${e.message}');
          }
        }
        attempts++;
      }
      talker.debug('SimklService: Login timed out.');
      return false;
    } catch (e) {
      talker.error('SimklService: Login failed', e);
      return false;
    }
  }

  @override
  Future<void> logout() async {
    talker.debug('SimklService: Logging out...');
    _accessToken = null;
    await _storage.remove('simkl_access_token');
  }

  @override
  Future<List<MultimediaItem>> search(String query) async {
    if (_accessToken == null) return [];
    
    // Search implementation
    return [];
  }

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async {
    final Map<String, String> resolvedIds = {};
    
    try {
      final queryParams = <String, String>{
        'client_id': _clientId,
      };
      
      if (item.imdbId != null) {
        queryParams['imdb'] = item.imdbId!;
      } else if (item.tmdbId != null) {
        queryParams['tmdb'] = item.tmdbId.toString();
      } else {
        return {};
      }

      final response = await _dio.get<List<dynamic>>(
        'https://api.simkl.com/search/id',
        queryParameters: queryParams,
      );

      if (response.statusCode == 200 && response.data != null && response.data!.isNotEmpty) {
        final result = response.data!.first as Map<String, dynamic>;
        
        final ids = result['ids'] as Map<String, dynamic>?;
        if (ids != null) {
          if (ids['simkl'] != null) resolvedIds['simkl'] = ids['simkl'].toString();
          if (ids['mal'] != null) resolvedIds['mal'] = ids['mal'].toString();
          if (ids['anilist'] != null) resolvedIds['anilist'] = ids['anilist'].toString();
          if (ids['tmdb'] != null) resolvedIds['tmdb'] = ids['tmdb'].toString();
          if (ids['imdb'] != null) resolvedIds['imdb'] = ids['imdb'].toString();
        }
      }
    } catch (e) {
      // Ignore
    }
    
    return resolvedIds;
  }

  Future<bool> _syncList(MultimediaItem item, Episode? episode, String listType, Map<String, String>? resolvedIds) async {
    if (_accessToken == null) return false;
    
    final simklId = resolvedIds?['simkl'];
    // We need simkl id or other ids. We'll send TMDB/IMDB directly if available.
    if (simklId == null && item.tmdbId == null && item.imdbId == null) return false;

    try {
      final payload = <String, dynamic>{};
      final ids = <String, dynamic>{
        'simkl': ?simklId,
        if (simklId == null && item.tmdbId != null) 'tmdb': item.tmdbId,
        if (simklId == null && item.imdbId != null) 'imdb': item.imdbId,
      };

      if (item.contentType == MultimediaContentType.movie) {
        payload['movies'] = [
          {'to': listType, 'ids': ids}
        ];
      } else {
        payload['shows'] = [
          {'to': listType, 'ids': ids}
        ];
      }

      final response = await _dio.post<dynamic>(
        'https://api.simkl.com/sync/add-to-list',
        data: payload,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'simkl-api-key': _clientId,
          },
        ),
      );
      talker.debug('SimklService: Add to list $listType success: ${response.statusCode}');
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      talker.error('SimklService: Add to list $listType failed', e);
      return false;
    }
  }

  @override
  Future<bool> markWatched(MultimediaItem item, Episode? episode, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    final simklId = resolvedIds?['simkl'];
    if (simklId == null && item.tmdbId == null && item.imdbId == null) return false;

    try {
      final payload = <String, dynamic>{};
      final ids = <String, dynamic>{
        'simkl': ?simklId,
        if (simklId == null && item.tmdbId != null) 'tmdb': item.tmdbId,
        if (simklId == null && item.imdbId != null) 'imdb': item.imdbId,
      };

      if (item.contentType == MultimediaContentType.movie) {
        payload['movies'] = [{'ids': ids}];
      } else {
        if (episode == null) return false;
        payload['shows'] = [
          {
            'ids': ids,
            'episodes': [
              {
                'season': episode.season,
                'number': episode.episode,
              }
            ]
          }
        ];
      }

      final response = await _dio.post<dynamic>(
        'https://api.simkl.com/sync/history',
        data: payload,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'simkl-api-key': _clientId,
          },
        ),
      );
      talker.debug('SimklService: Mark watched success: ${response.statusCode}');
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      talker.error('SimklService: Mark watched failed', e);
      return false;
    }
  }

  @override
  Future<bool> scrobbleStart(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    // Simkl doesn't have real-time scrobble, so we add to watching list
    return _syncList(item, episode, 'watching', resolvedIds);
  }

  @override
  Future<bool> scrobblePause(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    // No-op for Simkl
    return true;
  }

  @override
  Future<bool> scrobbleStop(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    // No-op for Simkl. Actual completion is handled by markWatched.
    return true;
  }

  @override
  Future<bool> addToPlanToWatch(MultimediaItem item, {Map<String, String>? resolvedIds}) async {
    return _syncList(item, null, 'plantowatch', resolvedIds);
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
SimklService simklService(Ref ref) {
  return SimklService(
    ref.watch(dioClientProvider),
    ref.watch(storageServiceProvider),
  );
}
