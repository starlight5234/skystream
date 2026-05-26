abstract class SkipService {
  /// Unique identifier for the skip service
  String get name;

  /// Fetch skip segments for a specific episode
  /// 
  /// The [tmdbId], [imdbId], or [anilistId] can be used depending on the service.
  Future<List<SkipSegment>> getSkipSegments({
    int? tmdbId,
    String? imdbId,
    int? anilistId,
    required int season,
    required int episode,
    int? duration,
  });
}

class SkipSegment {
  final double startTime; // in seconds
  final double endTime; // in seconds
  final SkipType type;

  SkipSegment({
    required this.startTime,
    required this.endTime,
    required this.type,
  });
}

enum SkipType {
  intro,
  outro,
  recap,
  unknown;

  static SkipType fromString(String type) {
    switch (type.toLowerCase()) {
      case 'intro':
      case 'new intro':
        return SkipType.intro;
      case 'outro':
      case 'credits':
        return SkipType.outro;
      case 'recap':
        return SkipType.recap;
      default:
        return SkipType.unknown;
    }
  }
}
