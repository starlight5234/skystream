import 'dart:async';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/models/extension_plugin.dart';
import '../../../core/services/notification_service.dart';
import '../../../shared/widgets/loading_dialog.dart';
import '../../details/presentation/playback_launcher.dart';
import '../../extensions/providers/extensions_controller.dart';

import 'package:skystream_watchparty/skystream_watchparty.dart';

class WatchPartyPlaybackBridge {
  static Future<bool> handlePlaybackInterception(
    Ref ref,
    BuildContext context,
    String url, {
    required MultimediaItem baseItem,
    MultimediaItem? detailedItem,
  }) async {
    final activeParty = ref.read(activeWatchPartyProvider);
    if (activeParty == null) return false;

    final partySettings = await WatchPartySettings.loadFromPrefs();
    if (!context.mounted) return false;

    final promptResult = await WatchPartyPlayPromptDialog.show(
      context,
      settings: partySettings,
    );
    if (!context.mounted) return false;

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
      ref.read(activeWatchPartyProvider.notifier).setActiveMedia(
        payload,
        waitForMembers: promptResult.waitForMembers,
      );
    }
    return true;
  }

  static Future<void> launchMedia(
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

    final launcher = ref.read(playbackLauncherProvider);

    if (providerName != null && providerName.isNotEmpty) {
      final ready = await _ensureExtensionInstalled(ref, context, providerName);
      if (!ready || !context.mounted) return;
    }

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

    final targetUrl = (episodeUrl != null && episodeUrl.isNotEmpty) ? episodeUrl : mediaUrl;

    await launcher.play(
      context,
      targetUrl,
      baseItem: item,
      detailedItem: item,
      isJoiningStream: true,
    );
  }

  static Future<bool> _ensureExtensionInstalled(
    WidgetRef ref,
    BuildContext context,
    String providerName,
  ) async {
    if (providerName.isEmpty) return true;

    final manager = ref.read(extensionManagerProvider.notifier);
    final isInstalled = manager.getAllProviders().any(
          (p) => p.packageName == providerName || p.name == providerName,
        );
    if (isInstalled) return true;

    bool dialogDismissed = false;
    unawaited(
      LoadingDialog.show(
        context,
        message: 'Installing required extension ($providerName)...',
        onCancel: () {
          dialogDismissed = true;
        },
      ),
    );

    try {
      final extController = ref.read(extensionsControllerProvider.notifier);
      await extController.ensureInitialized();

      final state = ref.read(extensionsControllerProvider);
      ExtensionPlugin? targetPlugin;

      if (state is ExtensionsSuccess) {
        for (final list in state.availablePlugins.values) {
          final found = list.firstWhereOrNull(
            (p) => p.packageName == providerName || p.name == providerName,
          );
          if (found != null) {
            targetPlugin = found;
            break;
          }
        }
      }

      if (targetPlugin != null) {
        await extController.installPlugin(targetPlugin);
      }
    } catch (_) {}

    if (!dialogDismissed && context.mounted) {
      Navigator.of(context).pop();
    }

    final nowInstalled = manager.getAllProviders().any(
          (p) => p.packageName == providerName || p.name == providerName,
        );

    if (!nowInstalled && context.mounted) {
      ref.read(notificationServiceProvider).showError(
            'Could not install missing extension "$providerName". Please install it from Extensions.',
          );
      return false;
    }

    return true;
  }
}
