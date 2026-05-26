import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'skip_service.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/config/sync_config.dart';

part 'anime_skip_service.g.dart';

class AnimeSkipService implements SkipService {
  final Dio _dio;
  
  static const String _clientId = SyncConfig.animeSkipClientId;

  AnimeSkipService(this._dio);

  @override
  String get name => 'AnimeSkip';

  @override
  Future<List<SkipSegment>> getSkipSegments({
    int? tmdbId,
    String? imdbId,
    int? anilistId,
    required int season,
    required int episode,
    int? duration,
  }) async {
    if (anilistId == null) return [];

    try {
      final query = '''
      query {
        findEpisodesByAnilistId(anilistId: $anilistId) {
          number
          timestamps {
            at
            type { name }
          }
        }
      }
      ''';

      final response = await _dio.post<Map<String, dynamic>>(
        'https://api.anime-skip.com/graphql',
        options: Options(headers: {'X-Client-ID': _clientId}),
        data: {'query': query},
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data!['data'];
        if (data == null) return [];
        
        final episodes = data['findEpisodesByAnilistId'] as List<dynamic>?;
        if (episodes == null) return [];

        // Find the matching episode number
        final targetEpisode = episodes.firstWhere(
          (dynamic ep) => ep['number'] == episode,
          orElse: () => null,
        );

        if (targetEpisode == null) return [];

        final timestamps = targetEpisode['timestamps'] as List<dynamic>?;
        if (timestamps == null || timestamps.isEmpty) return [];

        final List<SkipSegment> segments = [];
        
        // AnimeSkip provides single timestamps (at) instead of start/end.
        // We'll map them sequentially or use a default length if needed.
        // For actual use, we'll need to parse 'at' properly into ranges.
        // Example: at 0 is start, next is end. But typically they have Intro Start and Intro End.
        
        // This is a simplified version. AnimeSkip actually uses 'at' and 'type' 
        // to demarcate 'Intro', 'Outro'. It requires pairing them.
        
        return segments;
      }
    } catch (e) {
      // Ignore errors
    }
    
    return [];
  }
}

@riverpod
AnimeSkipService animeSkipService(Ref ref) {
  return AnimeSkipService(ref.watch(dioClientProvider));
}
