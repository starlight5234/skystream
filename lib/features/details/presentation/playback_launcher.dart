import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/external_player_service.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/providers.dart';
import '../../settings/presentation/player_settings_provider.dart';
import 'package:collection/collection.dart';
import 'details_controller.dart';
import '../../../core/services/download_service.dart';
import '../../../shared/widgets/loading_dialog.dart';
import '../../../core/utils/app_utils.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import '../../../core/services/notification_service.dart';
import 'package:skystream_watchparty/skystream_watchparty.dart';

part 'playback_launcher.g.dart';

@Riverpod(keepAlive: true)
PlaybackLauncher playbackLauncher(Ref ref) {
  return PlaybackLauncher(ref);
}

class PlaybackLauncher {
  final Ref _ref;

  PlaybackLauncher(this._ref);

  static Future<void> launchWatchPartyMedia(
    WidgetRef ref,
    BuildContext context,
    Map<String, dynamic> mediaPayload,
  ) async {
    final mediaUrl = mediaPayload['mediaUrl'] as String? ?? '';
    final episodeUrl = mediaPayload['episodeUrl'] as String?;
    final title = mediaPayload['title'] as String? ?? 'Shared Media';
    final posterUrl = mediaPayload['posterUrl'] as String?;
    final providerName = mediaPayload['providerName'] as String?;
    final season = mediaPayload['season'] as int? ?? 0;
    final episodeNumber = mediaPayload['episodeNumber'] as int? ?? 0;
    final episodeName = mediaPayload['episodeName'] as String?;

    final episode = (episodeUrl != null && episodeUrl.isNotEmpty)
        ? Episode(
            name: episodeName ?? 'Episode $episodeNumber',
            url: episodeUrl,
            season: season,
            episode: episodeNumber,
          )
        : null;

    final item = MultimediaItem(
      title: title,
      url: mediaUrl,
      posterUrl: posterUrl ?? '',
      provider: providerName ?? '',
      episodes: episode != null ? [episode] : null,
    );

    final launcher = ref.read(playbackLauncherProvider);
    final targetUrl = (episodeUrl != null && episodeUrl.isNotEmpty) ? episodeUrl : mediaUrl;

    await launcher.play(
      context,
      targetUrl,
      baseItem: item,
      detailedItem: item,
    );
  }

  Future<void> play(
    BuildContext context,
    String url, {
    required MultimediaItem baseItem,
    MultimediaItem? detailedItem,
  }) async {
    final settings = await _ref.read(playerSettingsProvider.future);
    if (!context.mounted) return;

    // WatchParty Playback Interception Check
    final activeParty = _ref.read(activeWatchPartyProvider);
    if (activeParty != null) {
      final partySettings = await WatchPartySettings.loadFromPrefs();
      if (!context.mounted) return;
      final promptResult = await WatchPartyPlayPromptDialog.show(
        context,
        settings: partySettings,
      );
      if (!context.mounted) return;
      if (promptResult != null && promptResult.choice == WatchPartyPlayChoice.watchTogether) {
        final item = detailedItem ?? baseItem;
        final episode = item.episodes?.firstWhereOrNull((e) => e.url == url);
        final payload = {
          'title': item.title,
          'posterUrl': item.posterUrl,
          'mediaUrl': item.url,
          'isTvShow': episode != null || (item.episodes != null && item.episodes!.isNotEmpty),
          'episodeUrl': episode?.url,
          'season': episode?.season,
          'episodeNumber': episode?.episode,
          'episodeName': episode?.name,
          'providerName': item.provider,
        };
        activeParty.chatService.sendMediaCard(payload);
        _ref.read(activeWatchPartyProvider.notifier).setActiveMedia(
          payload,
          waitForMembers: promptResult.waitForMembers,
        );
      }
    }

    // Smart Intercept: Check if this item/episode is downloaded
    final itemToCheck = detailedItem ?? baseItem;
    final episode = itemToCheck.episodes?.firstWhereOrNull((e) => e.url == url);
    final downloadService = _ref.read(downloadServiceProvider);
    final localFile = await downloadService.getDownloadedFile(
      itemToCheck,
      episode: episode,
    );
    if (!context.mounted) return;

    final String finalUrl = AppUtils.normalizeUrl(localFile?.path ?? url);

    if (settings.preferredPlayer != null) {
      if (baseItem.url.isNotEmpty) {
        _ref
            .read(detailsControllerProvider(baseItem.url).notifier)
            .setLaunching(true);
      }
      await _launchExternal(
        context,
        finalUrl,
        detailedItem ?? baseItem,
        settings.preferredPlayer!,
      ).whenComplete(() {
        if (baseItem.url.isNotEmpty) {
          _ref
              .read(detailsControllerProvider(baseItem.url).notifier)
              .setLaunching(false);
        }
      });
    } else {
      await PlayerRoute(
        $extra: PlayerRouteExtra(
          item: detailedItem ?? baseItem,
          videoUrl: finalUrl,
          episode: episode,
        ),
      ).push<void>(context);
    }
  }

  Future<void> _launchExternal(
    BuildContext context,
    String episodeDataUrl,
    MultimediaItem item,
    String playerId,
  ) async {
    // If it's a local file, we can skip stream resolution
    if (AppUtils.isLocalFile(episodeDataUrl)) {
      final stream = StreamResult(url: episodeDataUrl, source: 'Local');
      await _launchStream(context, stream, item, episodeDataUrl, playerId);
      return;
    }

    bool isCanceled = false;
    bool dialogDismissed = false;
    unawaited(
      LoadingDialog.show(
        context,
        message: AppLocalizations.of(context)!.resolving,
        onCancel: () {
          isCanceled = true;
          dialogDismissed = true;
        },
      ),
    );

    try {
      final manager = _ref.read(extensionManagerProvider.notifier);
      SkyStreamProvider? provider;
      if (item.provider != null) {
        try {
          final val = item.provider!;
          provider = manager.getAllProviders().firstWhere(
            (p) => p.packageName == val || p.name == val,
          );
        } catch (e) {
          if (kDebugMode) debugPrint('PlaybackLauncher.launch: $e');
        }
      }
      provider ??= _ref.read(activeProviderProvider);
      if (provider == null) throw Exception('No active provider');

      final streams = await provider.loadStreams(episodeDataUrl);
      if (isCanceled || !context.mounted) return;

      if (!dialogDismissed) {
        Navigator.of(context).pop(); // Dismiss loading dialog
        dialogDismissed = true;
      }

      if (streams.isEmpty) {
        final playerName =
            ExternalPlayerService.instance
                .getPlayerById(playerId)
                ?.displayName ??
            playerId;
        _ref
            .read(notificationServiceProvider)
            .showError(
              AppLocalizations.of(context)!.playerNotDetected(playerName),
            );
        unawaited(
          PlayerRoute(
            $extra: PlayerRouteExtra(item: item, videoUrl: episodeDataUrl),
          ).push<void>(context),
        );
        return;
      }

      if (streams.length == 1) {
        await _launchStream(
          context,
          streams.first,
          item,
          episodeDataUrl,
          playerId,
        );
      } else {
        if (item.url.isNotEmpty) {
          _ref
              .read(detailsControllerProvider(item.url).notifier)
              .setLaunching(false);
        }
        _showSourcePicker(context, streams, item, episodeDataUrl, playerId);
      }
    } catch (e) {
      if (!context.mounted) return;
      if (!isCanceled && !dialogDismissed) {
        Navigator.of(context).pop(); // Dismiss if still there
        dialogDismissed = true;
      }
      _ref
          .read(notificationServiceProvider)
          .showError(
            AppLocalizations.of(
              context,
            )!.usingInternalPlayerError(e.toString()),
          );
      unawaited(
        PlayerRoute(
          $extra: PlayerRouteExtra(item: item, videoUrl: episodeDataUrl),
        ).push<void>(context),
      );
    }
  }

  Future<void> _launchStream(
    BuildContext context,
    StreamResult stream,
    MultimediaItem item,
    String episodeDataUrl,
    String playerId,
  ) async {
    String playUrl = stream.url;
    if (stream.url.startsWith("magnet:") ||
        stream.url.endsWith(".torrent") ||
        (stream.url.startsWith("/") && stream.source.contains("Torrent"))) {
      final torrentUrl = await _ref
          .read(torrentServiceProvider)
          .getStreamUrl(stream.url);
      if (torrentUrl != null) {
        playUrl = torrentUrl;
      }
    }

    final success = await ExternalPlayerService.instance.launch(
      playUrl,
      headers: stream.headers,
      playerId: playerId,
      title: item.title,
    );

    if (!success && context.mounted) {
      final playerName =
          ExternalPlayerService.instance.getPlayerById(playerId)?.displayName ??
          playerId;
      _ref
          .read(notificationServiceProvider)
          .showError(
            AppLocalizations.of(context)!.playerNotDetected(playerName),
          );
      unawaited(
        PlayerRoute(
          $extra: PlayerRouteExtra(item: item, videoUrl: episodeDataUrl),
        ).push<void>(context),
      );
    }
  }

  void _showSourcePicker(
    BuildContext context,
    List<StreamResult> streams,
    MultimediaItem item,
    String episodeDataUrl,
    String playerId,
  ) {
    final playerName =
        ExternalPlayerService.instance.getPlayerById(playerId)?.displayName ??
        playerId;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  AppLocalizations.of(
                    context,
                  )!.selectSourceForPlayer(playerName),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: streams.length,
                  itemBuilder: (context, index) {
                    final stream = streams[index];
                    final label = stream.source != 'Auto'
                        ? stream.source
                        : 'Source ${index + 1}';
                    final host = Uri.tryParse(stream.url)?.host ?? '';

                    return ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(label),
                      subtitle: host.isNotEmpty ? Text(host) : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        _launchStream(
                          context,
                          stream,
                          item,
                          episodeDataUrl,
                          playerId,
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
