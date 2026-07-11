import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/storage/settings_repository.dart';
import '../../settings/presentation/general_settings_provider.dart';
import 'watchparty_database.dart';

final watchPartyDatabaseProvider = Provider<WatchPartyDatabase>((ref) {
  final settings = ref.watch(generalSettingsProvider);
  return SupabaseWatchPartyDatabase(
    ref.watch(settingsRepositoryProvider),
    customId: settings.watchPartyProjectId,
    customKey: settings.watchPartyAnonKey,
  );
});

class SupabaseWatchPartyDatabase implements WatchPartyDatabase {
  final SettingsRepository _settingsRepository;
  final String? _customId;
  final String? _customKey;
  SupabaseClient? _cachedClient;
  String? _cachedId;
  String? _cachedKey;

  SupabaseWatchPartyDatabase(this._settingsRepository, {String? customId, String? customKey})
      : _customId = customId,
        _customKey = customKey;

  SupabaseClient? get _client {
    final id = _customId ?? _settingsRepository.getWatchPartyProjectId()?.trim() ?? '';
    final key = _customKey ?? _settingsRepository.getWatchPartyAnonKey()?.trim() ?? '';

    if (id.isEmpty || key.isEmpty) {
      return null;
    }

    if (_cachedClient != null && _cachedId == id && _cachedKey == key) {
      return _cachedClient;
    }

    try {
      _cachedId = id;
      _cachedKey = key;
      _cachedClient = SupabaseClient('https://$id.supabase.co', key);
      return _cachedClient;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SupabaseWatchPartyDatabase init error: $e');
      }
      return null;
    }
  }

  @override
  bool isConfigured() {
    final id = _customId ?? _settingsRepository.getWatchPartyProjectId();
    final key = _customKey ?? _settingsRepository.getWatchPartyAnonKey();
    return id != null && id.trim().isNotEmpty && key != null && key.trim().isNotEmpty;
  }

  @override
  Future<void> createLobby({
    required String hostName,
    required String deviceType,
    required int maxGuests,
    required String passcodeHash,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Database not configured.');

    await client.from('watchparties').upsert({
      'host_name': hostName,
      'device_type': deviceType,
      'max_guests': maxGuests,
      'current_guest_count': 0,
      'allow_joins': true,
      'passcode_hash': passcodeHash,
      'signaling': [],
    });
  }

  @override
  Future<void> deleteLobby({
    required String hostName,
    required String passcodeHash,
  }) async {
    final client = _client;
    if (client == null) return;

    await client
        .from('watchparties')
        .delete()
        .eq('host_name', hostName)
        .eq('passcode_hash', passcodeHash);
  }

  @override
  Stream<Map<String, dynamic>?> subscribeToLobby({required String hostName}) {
    final client = _client;
    if (client == null) {
      return Stream.value(null);
    }

    return client
        .from('watchparties')
        .stream(primaryKey: ['host_name'])
        .eq('host_name', hostName)
        .map((list) => list.isEmpty ? null : list.first);
  }

  @override
  Future<Map<String, dynamic>?> getLobby({required String hostName}) async {
    final client = _client;
    if (client == null) return null;

    try {
      return await client
          .from('watchparties')
          .select()
          .eq('host_name', hostName)
          .maybeSingle();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> joinLobby({
    required String hostName,
    required String guestName,
    required String sdpOffer,
    required String passcodeHash,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Database not configured.');

    // Call the transaction-safe Postgres RPC function to safely check bounds and join
    final response = await client.rpc('join_watchparty', params: {
      'target_host_name': hostName,
      'joining_guest_name': guestName,
      'guest_offer': sdpOffer,
      'joining_passcode_hash': passcodeHash,
    });

    if (response == null) {
      throw Exception('Failed to join lobby.');
    }
  }

  @override
  Future<void> respondToLobby({
    required String hostName,
    required String guestName,
    required String sdpAnswer,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Database not configured.');

    final response = await getLobby(hostName: hostName);
    if (response == null) {
      throw Exception('Lobby not found.');
    }

    final signalingList = _parseSignaling(response['signaling']);
    final updatedList = List<Map<String, dynamic>>.from(
      signalingList.map((e) => Map<String, dynamic>.from(e as Map)),
    );

    bool found = false;
    for (final entry in updatedList) {
      if (entry['guest_name'] == guestName) {
        entry['host_answer'] = sdpAnswer;
        found = true;
        break;
      }
    }

    if (!found) {
      throw Exception('Guest not found in signaling list.');
    }

    await client.from('watchparties').update({
      'signaling': updatedList,
    }).eq('host_name', hostName);
  }

  @override
  Future<void> leaveLobby({required String hostName, required String guestName}) async {
    final client = _client;
    if (client == null) return;

    try {
      final response = await getLobby(hostName: hostName);
      if (response == null) return;

      final signalingList = _parseSignaling(response['signaling']);
      final updatedList = List<Map<String, dynamic>>.from(
        signalingList.map((e) => Map<String, dynamic>.from(e as Map)),
      );

      updatedList.removeWhere((element) => element['guest_name'] == guestName);

      await client.from('watchparties').update({
        'signaling': updatedList,
        'current_guest_count': updatedList.length,
      }).eq('host_name', hostName);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SupabaseWatchPartyDatabase leaveLobby error: $e');
      }
    }
  }

  List<dynamic> _parseSignaling(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded;
      } catch (_) {}
    }
    return [];
  }
}
