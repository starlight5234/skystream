import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'skip_service.dart';
import '../../../../core/network/dio_client_provider.dart';

part 'intro_db_service.g.dart';

class IntroDbService implements SkipService {
  final Dio _dio;

  IntroDbService(this._dio);

  @override
  String get name => 'IntroDB';

  @override
  Future<List<SkipSegment>> getSkipSegments({
    int? tmdbId,
    String? imdbId,
    int? anilistId,
    required int season,
    required int episode,
    int? duration,
  }) async {
    // IntroDB primarily uses IMDB id for Western TV/movies, or TMDB as fallback
    if (imdbId == null && tmdbId == null) {
      return [];
    }

    try {
      final queryParams = <String, dynamic>{
        'season': season,
        'episode': episode,
      };
      
      if (imdbId != null) {
        queryParams['imdb'] = imdbId;
      } else if (tmdbId != null) {
        queryParams['tmdb'] = tmdbId.toString();
      }

      final response = await _dio.get<List<dynamic>>(
        'https://api.intro-skipper.workers.dev/api/v1/segments',
        queryParameters: queryParams,
      );

      if (response.statusCode == 200 && response.data != null) {
        return response.data!.map((dynamic item) {
          final map = item as Map<String, dynamic>;
          return SkipSegment(
            startTime: (map['start'] as num).toDouble(),
            endTime: (map['end'] as num).toDouble(),
            type: SkipType.fromString(map['type'] as String),
          );
        }).toList();
      }
    } catch (e) {
      // Ignore errors (e.g. 404 if no skip data exists)
    }
    
    return [];
  }
}

@riverpod
IntroDbService introDbService(Ref ref) {
  return IntroDbService(ref.watch(dioClientProvider));
}
