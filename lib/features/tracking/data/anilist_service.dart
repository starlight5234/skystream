import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'tracking_service.dart';
import '../domain/sync_progress_item.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/config/sync_config.dart';

part 'anilist_service.g.dart';

class AniListService implements TrackingService {
  final Dio _dio;
  final StorageService _storage;
  
  static const String _clientId = SyncConfig.anilistClientId;
  
  String? _accessToken;

  AniListService(this._dio, this._storage) {
    _initToken();
  }

  void _initToken() {
    _accessToken = _storage.getString('anilist_access_token');
  }

  @override
  String get name => 'AniList';

  @override
  String get idPrefix => 'anilist';

  @override
  String get mainUrl => 'https://anilist.co';

  @override
  Future<bool> get isLoggedIn async => _accessToken != null;

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    try {
      talker.debug('AniListService: Initiating OAuth Flow...');
      const authUrl = 'https://anilist.co/api/v2/oauth/authorize?client_id=$_clientId&response_type=token';
      talker.debug('ANILIST LOGIN — open in browser/webview: $authUrl');

      if (onWebViewRequested != null) {
        await onWebViewRequested(authUrl);
      }
      return true;
    } catch (e) {
      talker.error('AniListService: Login error', e);
      return false;
    }
  }

  @override
  Future<void> logout() async {
    talker.debug('AniListService: Logging out...');
    _accessToken = null;
    await _storage.remove('anilist_access_token');
  }

  @override
  Future<List<MultimediaItem>> search(String query) async {
    if (_accessToken == null) return [];
    
    // GraphQL Search implementation
    return [];
  }

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async {
    // AniList IDs usually resolved via Simkl or MAL-Sync
    return {};
  }

  Future<bool> _saveMediaListEntry(int anilistId, {String? status, int? progress}) async {
    try {
      final variables = <String, dynamic>{
        'mediaId': anilistId,
      };
      if (status != null) variables['status'] = status;
      if (progress != null) variables['progress'] = progress;

      final response = await _dio.post<dynamic>(
        'https://graphql.anilist.co',
        data: {
          'query': '''
            mutation (\$mediaId: Int, \$status: MediaListStatus, \$progress: Int) {
              SaveMediaListEntry(mediaId: \$mediaId, status: \$status, progress: \$progress) {
                id
                status
                progress
              }
            }
          ''',
          'variables': variables,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );

      talker.debug('AniListService: SaveMediaListEntry success: ${response.statusCode}');
      return response.statusCode == 200;
    } catch (e) {
      talker.error('AniListService: SaveMediaListEntry failed', e);
      return false;
    }
  }

  @override
  Future<bool> markWatched(MultimediaItem item, Episode? episode, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    final anilistIdStr = resolvedIds?['anilist'];
    if (anilistIdStr == null) return false;
    
    final anilistId = int.tryParse(anilistIdStr);
    if (anilistId == null) return false;

    if (item.contentType == MultimediaContentType.movie) {
      return _saveMediaListEntry(anilistId, status: 'COMPLETED');
    } else {
      if (episode == null) return false;
      return _saveMediaListEntry(anilistId, progress: episode.episode);
    }
  }

  @override
  Future<bool> scrobbleStart(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    final anilistIdStr = resolvedIds?['anilist'];
    if (anilistIdStr == null) return false;
    
    final anilistId = int.tryParse(anilistIdStr);
    if (anilistId == null) return false;

    // Set status to CURRENT (Watching)
    return _saveMediaListEntry(anilistId, status: 'CURRENT');
  }

  @override
  Future<bool> scrobblePause(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    // No-op for AniList
    return true;
  }

  @override
  Future<bool> scrobbleStop(MultimediaItem item, Episode? episode, double progress, {Map<String, String>? resolvedIds}) async {
    // No-op for AniList
    return true;
  }

  @override
  Future<bool> addToPlanToWatch(MultimediaItem item, {Map<String, String>? resolvedIds}) async {
    if (_accessToken == null) return false;
    final anilistIdStr = resolvedIds?['anilist'];
    if (anilistIdStr == null) return false;
    
    final anilistId = int.tryParse(anilistIdStr);
    if (anilistId == null) return false;

    return _saveMediaListEntry(anilistId, status: 'PLANNING');
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
AniListService aniListService(Ref ref) {
  return AniListService(
    ref.watch(dioClientProvider),
    ref.watch(storageServiceProvider),
  );
}
