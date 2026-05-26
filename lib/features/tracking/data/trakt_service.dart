import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'tracking_service.dart';
import '../domain/sync_progress_item.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/config/sync_config.dart';

part 'trakt_service.g.dart';

class TraktService implements TrackingService {
  final Dio _dio;
  final StorageService _storage;
  
  static const String _clientId = SyncConfig.traktClientId;
  
  String? _accessToken;

  TraktService(this._dio, this._storage) {
    _initToken();
  }

  void _initToken() {
    _accessToken = _storage.getString('trakt_access_token');
  }

  @override
  String get name => 'Trakt';

  @override
  String get idPrefix => 'trakt';

  @override
  String get mainUrl => 'https://trakt.tv';

  @override
  Future<bool> get isLoggedIn async => _accessToken != null;

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    try {
      print('TraktService: Initiating Device PIN Flow...');
      final response = await _dio.post(
        'https://api.trakt.tv/oauth/device/code',
        data: {'client_id': _clientId},
      );
      
      final userCode = response.data['user_code'] as String;
      final deviceCode = response.data['device_code'] as String;
      final verificationUrl = response.data['verification_url'] as String;
      final interval = (response.data['interval'] as num?)?.toInt() ?? 5;
      
      print('=============================================');
      print('TRAKT DEVICE LOGIN');
      print('1. Go to: $verificationUrl');
      print('2. Enter code: $userCode');
      print('=============================================');

      if (onDeviceCodeGenerated != null) {
        await onDeviceCodeGenerated(verificationUrl, userCode);
      }
      
      // Polling
      int attempts = 0;
      while (attempts < 60) {
        if (isCancelled != null && isCancelled()) {
          print('TraktService: Polling cancelled by user.');
          return false;
        }
        await Future.delayed(Duration(seconds: interval));
        if (isCancelled != null && isCancelled()) return false;
        
        try {
          print('TraktService: Polling for token...');
          final tokenResponse = await _dio.post(
            'https://api.trakt.tv/oauth/device/token',
            data: {
              'code': deviceCode,
              'client_id': _clientId,
              'client_secret': SyncConfig.traktClientSecret,
            },
          );
          
          final data = tokenResponse.data;
          if (tokenResponse.statusCode == 200 && data is Map && data['access_token'] != null) {
            _accessToken = data['access_token'].toString();
            await _storage.setString('trakt_access_token', _accessToken!);
            print('TraktService: Login successful!');
            return true;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode != 400) { // 400 = authorization_pending
            print('TraktService: Polling error: ${e.response?.statusCode} ${e.message}');
            if (e.response?.statusCode == 404 || e.response?.statusCode == 409 || e.response?.statusCode == 410 || e.response?.statusCode == 418) {
               // 404 Not Found, 409 Already Used, 410 Expired, 418 Denied
               print('TraktService: Terminal error, stopping polling.');
               return false;
            }
          }
        }
        attempts++;
      }
      print('TraktService: Login timed out.');
      return false;
    } catch (e) {
      print('TraktService: Login failed: $e');
      return false;
    }
  }

  @override
  Future<void> logout() async {
    print('TraktService: Logging out...');
    _accessToken = null;
    await _storage.remove('trakt_access_token');
  }

  @override
  Future<List<MultimediaItem>> search(String query) async {
    if (_accessToken == null) return [];
    
    // Search implementation
    return [];
  }

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async {
    // Trakt uses IMDB and TMDB directly in scrobbling, so we don't strictly need 
    // a separate ID resolution unless we want the Trakt slug.
    return {};
  }

  Map<String, dynamic> _buildScrobblePayload(MultimediaItem item, Episode? episode, double progress) {
    final payload = <String, dynamic>{
      'progress': progress * 100,
      'app_version': '1.0',
      'app_date': '2024-05-26',
    };

    if (item.contentType == MultimediaContentType.movie) {
      payload['movie'] = {
        'ids': {
          if (item.tmdbId != null) 'tmdb': item.tmdbId,
          if (item.imdbId != null) 'imdb': item.imdbId,
        }
      };
    } else {
      payload['show'] = {
        'ids': {
          if (item.tmdbId != null) 'tmdb': item.tmdbId,
          if (item.imdbId != null) 'imdb': item.imdbId,
        }
      };
      if (episode != null) {
        payload['episode'] = {
          'season': episode.season,
          'number': episode.episode,
        };
      }
    }
    return payload;
  }

  Future<bool> _scrobble(String action, MultimediaItem item, Episode? episode, double progress) async {
    if (_accessToken == null) return false;
    if (item.tmdbId == null && item.imdbId == null) {
      print('TraktService: Cannot scrobble, no TMDB/IMDB ID available');
      return false;
    }

    try {
      final payload = _buildScrobblePayload(item, episode, progress);
      final response = await _dio.post(
        'https://api.trakt.tv/scrobble/$action',
        data: payload,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'trakt-api-version': '2',
            'trakt-api-key': _clientId,
            'Authorization': 'Bearer $_accessToken',
          },
        ),
      );
      print('TraktService: Scrobble $action success: ${response.statusCode}');
      return response.statusCode == 201 || response.statusCode == 200;
    } catch (e) {
      print('TraktService: Scrobble $action failed: $e');
      return false;
    }
  }

  @override
  Future<bool> markWatched(MultimediaItem item, Episode? episode, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    if (item.tmdbId == null && item.imdbId == null) return false;
    
    // We can use scrobble stop with progress >= 85 to mark as watched.
    // Trakt automatically marks it watched if progress >= 80.
    return _scrobble('stop', item, episode, 1.0); // Send 100% to ensure it's marked
  }

  @override
  Future<bool> scrobbleStart(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    return _scrobble('start', item, episode, progress);
  }

  @override
  Future<bool> scrobblePause(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    return _scrobble('pause', item, episode, progress);
  }

  @override
  Future<bool> scrobbleStop(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    return _scrobble('stop', item, episode, progress);
  }

  @override
  Future<bool> addToPlanToWatch(MultimediaItem item, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    if (item.tmdbId == null && item.imdbId == null) return false;

    try {
      final payload = <String, dynamic>{};
      if (item.contentType == MultimediaContentType.movie) {
        payload['movies'] = [
          {
            'ids': {
              if (item.tmdbId != null) 'tmdb': item.tmdbId,
              if (item.imdbId != null) 'imdb': item.imdbId,
            }
          }
        ];
      } else {
        payload['shows'] = [
          {
            'ids': {
              if (item.tmdbId != null) 'tmdb': item.tmdbId,
              if (item.imdbId != null) 'imdb': item.imdbId,
            }
          }
        ];
      }

      final response = await _dio.post(
        'https://api.trakt.tv/sync/watchlist',
        data: payload,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'trakt-api-version': '2',
            'trakt-api-key': _clientId,
            'Authorization': 'Bearer $_accessToken',
          },
        ),
      );
      print('TraktService: Added to watchlist: ${response.statusCode}');
      return response.statusCode == 201 || response.statusCode == 200;
    } catch (e) {
      print('TraktService: Add to watchlist failed: $e');
      return false;
    }
  }

  @override
  Future<List<SyncProgressItem>> pullPlaybackProgress() async {
    if (_accessToken == null) return [];

    try {
      final response = await _dio.get(
        'https://api.trakt.tv/sync/playback',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'trakt-api-version': '2',
            'trakt-api-key': _clientId,
            'Authorization': 'Bearer $_accessToken',
          },
        ),
      );

      if (response.statusCode == 200 && response.data is List) {
        final items = response.data as List;
        return items.map((json) => SyncProgressItem.fromJson(json as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      print('TraktService: Pull playback progress failed: $e');
    }
    return [];
  }

  @override
  Future<bool> removePlaybackProgress(String id) async {
    if (_accessToken == null) return false;
    try {
      final response = await _dio.delete(
        'https://api.trakt.tv/sync/playback/$id',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'trakt-api-version': '2',
            'trakt-api-key': _clientId,
            'Authorization': 'Bearer $_accessToken',
          },
        ),
      );
      return response.statusCode == 204;
    } catch (e) {
      print('TraktService: Remove playback progress failed: $e');
      return false;
    }
  }
}

@riverpod
TraktService traktService(Ref ref) {
  return TraktService(
    ref.watch(dioClientProvider),
    ref.watch(storageServiceProvider),
  );
}
