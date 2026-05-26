import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/layout_constants.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'widgets/settings_widgets.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/tracking_auth_dialog.dart';
import 'widgets/webview_auth_dialog.dart';
import 'player_settings_provider.dart';

import '../../tracking/presentation/tracking_auth_provider.dart';
import '../../tracking/data/simkl_service.dart';
import '../../tracking/data/trakt_service.dart';
import '../../tracking/data/mal_service.dart';
import '../../tracking/data/anilist_service.dart';

class AccountSettingsScreen extends ConsumerWidget {
  const AccountSettingsScreen({super.key});

  Future<bool> _confirmDisconnect(
    BuildContext context,
    String providerName,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect $providerName'),
        content: Text(
          'Are you sure you want to disconnect your $providerName account?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Disconnect',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playerSettings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.accounts)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.only(bottom: LayoutConstants.spacingLg),
            children: [
              const SizedBox(height: LayoutConstants.spacingXs),
              SettingsGroup(
                title: l10n.accounts,
                children: [
                  SettingsTile(
                    icon: Icons.subtitles_rounded,
                    title: l10n.openSubtitles,
                    subtitle: playerSettings.osUsername.isNotEmpty
                        ? l10n.loggedInAs(playerSettings.osUsername)
                        : l10n.notLoggedIn,
                    onTap: () => showOpenSubtitlesAuthDialog(
                      context,
                      ref,
                      playerSettings,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.vpn_key_rounded,
                    title: l10n.subDl,
                    subtitle: playerSettings.subdlApiKey.isNotEmpty
                        ? l10n.apiKeyConfigured
                        : l10n.keyNotSet,
                    onTap: () =>
                        showSubDlAuthDialog(context, ref, playerSettings),
                  ),
                  SettingsTile(
                    icon: Icons.vpn_key_rounded,
                    title: l10n.subSource,
                    subtitle: playerSettings.subsourceApiKey.isNotEmpty
                        ? l10n.apiKeyConfigured
                        : l10n.keyNotSet,
                    onTap: () =>
                        showSubSourceAuthDialog(context, ref, playerSettings),
                  ),
                  Consumer(
                    builder: (context, ref, _) {
                      final trackingAuthAsync = ref.watch(trackingAuthProvider);
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SettingsTile(
                            icon: Icons.sync_rounded,
                            title: 'Simkl',
                            subtitle: trackingAuthAsync.when(
                              data: (state) => state['simkl'] == true
                                  ? 'Connected'
                                  : l10n.notLoggedIn,
                              loading: () => l10n.loading,
                              error: (_, __) => l10n.unknown,
                            ),
                            onTap: () async {
                              final state = trackingAuthAsync.value ?? {};
                              if (state['simkl'] == true) {
                                final confirm = await _confirmDisconnect(
                                  context,
                                  'Simkl',
                                );
                                if (confirm) {
                                  await ref.read(simklServiceProvider).logout();
                                  ref.invalidate(trackingAuthProvider);
                                  if (context.mounted) {
                                    FocusScope.of(context).requestFocus();
                                  }
                                }
                              } else {
                                bool isCancelled = false;
                                bool isDialogShowing = false;
                                BuildContext? dialogContext;
                                final success = await ref
                                    .read(simklServiceProvider)
                                    .login(
                                      isCancelled: () => isCancelled,
                                      onDeviceCodeGenerated: (url, code) async {
                                        if (context.mounted) {
                                          isDialogShowing = true;
                                          showDialog(
                                            context: context,
                                            barrierDismissible: true,
                                            builder: (ctx) {
                                              dialogContext = ctx;
                                              return TrackingAuthDialog(
                                                providerName: 'Simkl',
                                                verificationUrl: url,
                                                userCode: code,
                                              );
                                            },
                                          ).then((_) {
                                            isCancelled = true;
                                            isDialogShowing = false;
                                            if (context.mounted) {
                                              FocusScope.of(
                                                context,
                                              ).requestFocus();
                                            }
                                          });
                                        }
                                      },
                                    );
                                if (success && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Successfully connected to Simkl!',
                                      ),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                                if (isDialogShowing &&
                                    dialogContext != null &&
                                    dialogContext!.mounted) {
                                  Navigator.of(dialogContext!).pop();
                                }
                              }
                              ref.invalidate(trackingAuthProvider);
                            },
                          ),
                          SettingsTile(
                            icon: Icons.sync_rounded,
                            title: 'Trakt',
                            subtitle: trackingAuthAsync.when(
                              data: (state) => state['trakt'] == true
                                  ? 'Connected'
                                  : l10n.notLoggedIn,
                              loading: () => l10n.loading,
                              error: (_, __) => l10n.unknown,
                            ),
                            onTap: () async {
                              final state = trackingAuthAsync.value ?? {};
                              if (state['trakt'] == true) {
                                final confirm = await _confirmDisconnect(
                                  context,
                                  'Trakt',
                                );
                                if (confirm) {
                                  await ref.read(traktServiceProvider).logout();
                                  ref.invalidate(trackingAuthProvider);
                                  if (context.mounted) {
                                    FocusScope.of(context).requestFocus();
                                  }
                                }
                              } else {
                                bool isCancelled = false;
                                bool isDialogShowing = false;
                                BuildContext? dialogContext;
                                final success = await ref
                                    .read(traktServiceProvider)
                                    .login(
                                      isCancelled: () => isCancelled,
                                      onDeviceCodeGenerated: (url, code) async {
                                        if (context.mounted) {
                                          isDialogShowing = true;
                                          showDialog(
                                            context: context,
                                            barrierDismissible: true,
                                            builder: (ctx) {
                                              dialogContext = ctx;
                                              return TrackingAuthDialog(
                                                providerName: 'Trakt',
                                                verificationUrl: url,
                                                userCode: code,
                                              );
                                            },
                                          ).then((_) {
                                            isCancelled = true;
                                            isDialogShowing = false;
                                            if (context.mounted) {
                                              FocusScope.of(
                                                context,
                                              ).requestFocus();
                                            }
                                          });
                                        }
                                      },
                                    );
                                if (success && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Successfully connected to Trakt!',
                                      ),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                                if (isDialogShowing &&
                                    dialogContext != null &&
                                    dialogContext!.mounted) {
                                  Navigator.of(dialogContext!).pop();
                                }
                              }
                              ref.invalidate(trackingAuthProvider);
                            },
                          ),
                          SettingsTile(
                            icon: Icons.sync_rounded,
                            title: 'MyAnimeList',
                            subtitle: trackingAuthAsync.when(
                              data: (state) => state['mal'] == true
                                  ? 'Connected'
                                  : l10n.notLoggedIn,
                              loading: () => l10n.loading,
                              error: (_, __) => l10n.unknown,
                            ),
                            onTap: () async {
                              final state = trackingAuthAsync.value ?? {};
                              if (state['mal'] == true) {
                                final confirm = await _confirmDisconnect(
                                  context,
                                  'MyAnimeList',
                                );
                                if (confirm) {
                                  await ref.read(malServiceProvider).logout();
                                  ref.invalidate(trackingAuthProvider);
                                  if (context.mounted) {
                                    FocusScope.of(context).requestFocus();
                                  }
                                }
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Coming soon')),
                                );
                                /*
                                await ref
                                    .read(malServiceProvider)
                                    .login(
                                      onWebViewRequested: (url) async {
                                        if (context.mounted) {
                                          final result =
                                              await showDialog<String>(
                                                context: context,
                                                builder: (context) =>
                                                    WebViewAuthDialog(
                                                      providerName:
                                                          'MyAnimeList',
                                                      initialUrl: url,
                                                      redirectUrlPrefix:
                                                          'http://localhost',
                                                    ),
                                              );
                                          if (result != null) {
                                            print('MAL Auth Result: $result');
                                          }
                                        }
                                      },
                                    );
                                */
                              }
                              ref.invalidate(trackingAuthProvider);
                            },
                          ),
                          SettingsTile(
                            icon: Icons.sync_rounded,
                            title: 'AniList',
                            subtitle: trackingAuthAsync.when(
                              data: (state) => state['anilist'] == true
                                  ? 'Connected'
                                  : l10n.notLoggedIn,
                              loading: () => l10n.loading,
                              error: (_, __) => l10n.unknown,
                            ),
                            isLast: true,
                            onTap: () async {
                              final state = trackingAuthAsync.value ?? {};
                              if (state['anilist'] == true) {
                                final confirm = await _confirmDisconnect(
                                  context,
                                  'AniList',
                                );
                                if (confirm) {
                                  await ref
                                      .read(aniListServiceProvider)
                                      .logout();
                                  ref.invalidate(trackingAuthProvider);
                                  if (context.mounted) {
                                    FocusScope.of(context).requestFocus();
                                  }
                                }
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Coming soon')),
                                );
                                /*
                                await ref
                                    .read(aniListServiceProvider)
                                    .login(
                                      onWebViewRequested: (url) async {
                                        if (context.mounted) {
                                          final result =
                                              await showDialog<String>(
                                                context: context,
                                                builder: (context) =>
                                                    WebViewAuthDialog(
                                                      providerName: 'AniList',
                                                      initialUrl: url,
                                                      redirectUrlPrefix:
                                                          'http://localhost',
                                                    ),
                                              );
                                          if (result != null) {
                                            print(
                                              'AniList Auth Result: $result',
                                            );
                                          }
                                        }
                                      },
                                    );
                                */
                              }
                              ref.invalidate(trackingAuthProvider);
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
