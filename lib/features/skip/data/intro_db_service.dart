import 'package:dio/dio.dart';
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
    // The new API seems to only support imdb_id
    if (imdbId == null) {
      return [];
    }

    try {
      final queryParams = <String, dynamic>{
        'season': season,
        'episode': episode,
        'imdb_id': imdbId,
      };

      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.introdb.app/segments',
        queryParameters: queryParams,
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data!;
        final segments = <SkipSegment>[];

        void addSegment(String key, SkipType type) {
          final segmentData = data[key];
          // If we use 'is Map' it's safer for dynamic JSON maps
          if (segmentData != null && segmentData is Map) {
            segments.add(
              SkipSegment(
                startTime: (segmentData['start_sec'] as num).toDouble(),
                endTime: (segmentData['end_sec'] as num).toDouble(),
                type: type,
              ),
            );
          }
        }

        addSegment('intro', SkipType.intro);
        addSegment('recap', SkipType.recap);
        addSegment('outro', SkipType.outro);

        return segments;
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
