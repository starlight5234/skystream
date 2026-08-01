import 'dart:async';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/models/extension_plugin.dart';
import '../../../core/services/notification_service.dart';
import '../../../shared/widgets/loading_dialog.dart';
import '../../details/presentation/playback_launcher.dart';
import '../../extensions/providers/extensions_controller.dart';

import 'package:skystream_watchparty/skystream_watchparty.dart';
import '../../../core/services/watchparty_bridge_interface.dart';

final watchPartyPlaybackInterceptorProvider = Provider<WatchPartyPlaybackInterceptor>((ref) {
  return WatchPartyPlaybackBridge();
});

class WatchPartyPlaybackBridge implements WatchPartyPlaybackInterceptor {
  @override
  Future<bool> interceptPlayback(
    Ref ref,
    BuildContext context,
    String url, {
    required MultimediaItem baseItem,
    MultimediaItem? detailedItem,
  }) async {
    return handlePlaybackInterception(
      ref,
      context,
      url,
      baseItem: baseItem,
      detailedItem: detailedItem,
    );
  }

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

      String? repoUrl;
      if (item.provider != null && item.provider!.isNotEmpty) {
        final extState = ref.read(extensionsControllerProvider);
        if (extState is ExtensionsSuccess) {
          // 1. Search availablePlugins by repo URL key
          for (final entry in extState.availablePlugins.entries) {
            if (entry.value.any((p) => p.packageName == item.provider || p.name == item.provider)) {
              repoUrl = entry.key;
              break;
            }
          }
          // 2. If not found in availablePlugins, fallback to installedPlugins -> repository lookup
          if (repoUrl == null) {
            final installed = extState.installedPlugins.firstWhereOrNull(
              (p) => p.packageName == item.provider || p.name == item.provider,
            );
            if (installed != null) {
              final repo = extState.repositories.firstWhereOrNull(
                (r) => r.url == installed.repositoryId || r.packageName == installed.repositoryId || r.name == installed.repositoryId,
              );
              repoUrl = repo?.url ?? (installed.repositoryId.startsWith('http') ? installed.repositoryId : null);
            }
          }
        }
      }

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
        'repoUrl': repoUrl,
        'sharer': activeParty.userName,
        'allowMemberControl': promptResult.allowMemberControl,
      };
      activeParty.chatService.sendMediaCard(payload);
      ref.read(activeWatchPartyProvider.notifier).setActiveMedia(
        payload,
        waitForMembers: promptResult.waitForMembers,
      );
      return false;
    } else if (promptResult != null && promptResult.choice == WatchPartyPlayChoice.skip) {
      return false;
    }
    return true;
  }

  static Future<void> launchMedia(
    WidgetRef ref,
    BuildContext context,
    Map<String, dynamic> mediaPayload,
  ) async {
    final activeParty = ref.read(activeWatchPartyProvider);
    if (activeParty != null) {
      ref.read(activeWatchPartyProvider.notifier).setActiveMedia(
        mediaPayload,
        waitForMembers: false,
      );
    }

    final mediaUrl = mediaPayload['mediaUrl'] as String? ?? '';
    final episodeUrl = mediaPayload['episodeUrl'] as String?;
    final title = mediaPayload['title'] as String? ?? 'Shared Media';
    final posterUrl = mediaPayload['posterUrl'] as String?;
    final providerName = mediaPayload['providerName'] as String?;
    final repoUrl = mediaPayload['repoUrl'] as String?;
    final season = mediaPayload['season'] as int? ?? 0;
    final episodeNumber = mediaPayload['episodeNumber'] as int? ?? 0;
    final episodeName = mediaPayload['episodeName'] as String?;

    final launcher = ref.read(playbackLauncherProvider);

    if (providerName != null && providerName.isNotEmpty) {
      final ready = await _ensureExtensionInstalled(
        ref,
        context,
        providerName,
        repoUrl: repoUrl,
      );
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
    String providerName, {
    String? repoUrl,
  }) async {
    if (providerName.isEmpty) return true;

    final manager = ref.read(extensionManagerProvider.notifier);
    final isInstalled = manager.getAllProviders().any(
          (p) => p.packageName == providerName || p.name == providerName,
        );
    if (isInstalled) return true;

    bool dialogShowing = false;
    bool dialogDismissed = false;

    try {
      final extController = ref.read(extensionsControllerProvider.notifier);
      await extController.ensureInitialized();

      var state = ref.read(extensionsControllerProvider);
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

      if (targetPlugin == null) {
        dialogShowing = true;
        unawaited(
          LoadingDialog.show(
            context,
            message: repoUrl != null
                ? 'Fetching repository & installing $providerName...'
                : 'Installing required extension ($providerName)...',
            onCancel: () {
              dialogDismissed = true;
            },
          ),
        );
      }

      // If missing and repoUrl is provided, add the repo automatically!
      if (targetPlugin == null && repoUrl != null && repoUrl.isNotEmpty) {
        await extController.addRepository(repoUrl);
        state = ref.read(extensionsControllerProvider);
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
      }

      if (targetPlugin != null) {
        if (!dialogShowing) {
          dialogShowing = true;
          unawaited(
            LoadingDialog.show(
              context,
              message: 'Installing required extension ($providerName)...',
              onCancel: () {
                dialogDismissed = true;
              },
            ),
          );
        }
        await extController.installPlugin(targetPlugin);
        final updatedState = ref.read(extensionsControllerProvider);
        await manager.syncFromPlugins(updatedState.installedPlugins);
      }
    } catch (_) {}

    if (dialogShowing && !dialogDismissed && context.mounted) {
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    final nowInstalled = manager.getAllProviders().any(
          (p) => p.packageName == providerName || p.name == providerName,
        );

    if (!nowInstalled && context.mounted) {
      ref.read(notificationServiceProvider).showError(
            'Extension "$providerName" could not be installed automatically.',
          );
      return false;
    }

    return true;
  }
}
