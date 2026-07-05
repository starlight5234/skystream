import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/storage/settings_repository.dart';
import 'watchparty_database.dart';

final watchPartyDatabaseProvider = Provider<WatchPartyDatabase>((ref) {
  return SupabaseWatchPartyDatabase(ref.watch(settingsRepositoryProvider));
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
    required String sdpOffer,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Database not configured.');

    await client.from('watchparties').upsert({
      'host_name': hostName,
      'device_type': deviceType,
      'max_guests': maxGuests,
      'current_guest_count': 0,
      'allow_joins': true,
      'sdp_offer': sdpOffer,
      'sdp_answers': [],
    });
  }

  @override
  Future<void> deleteLobby({required String hostName}) async {
    final client = _client;
    if (client == null) return;

    await client.from('watchparties').delete().eq('host_name', hostName);
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
    required String sdpAnswer,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Database not configured.');

    final response = await getLobby(hostName: hostName);
    if (response == null) {
      throw Exception('Lobby not found.');
    }

    final maxGuests = response['max_guests'] as int;
    final allowJoins = response['allow_joins'] as bool;
    final currentList = _parseSdpAnswers(response['sdp_answers']);

    if (!allowJoins) {
      throw Exception('Lobby is currently closed for new joins.');
    }

    final int currentCount = response['current_guest_count'] as int? ?? currentList.length;
    if (currentCount >= maxGuests) {
      throw Exception('Lobby is full.');
    }

    final updatedList = List<Map<String, dynamic>>.from(
      currentList.map((e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>)),
    );
    
    updatedList.removeWhere((element) => element['guestName'] == guestName);
    
    updatedList.add({
      'guestName': guestName,
      'answer': sdpAnswer,
    });

    final updateResponse = await client.from('watchparties').update({
      'sdp_answers': updatedList,
      'current_guest_count': updatedList.length,
    }).eq('host_name', hostName)
      .eq('current_guest_count', currentCount)
      .select();

    if (updateResponse.isEmpty) {
      throw Exception('Lobby join race condition. Lobby was updated by another guest.');
    }
  }

  @override
  Future<void> leaveLobby({required String hostName, required String guestName}) async {
    final client = _client;
    if (client == null) return;

    try {
      final response = await getLobby(hostName: hostName);
      if (response == null) return;

      final currentList = _parseSdpAnswers(response['sdp_answers']);
      final updatedList = List<Map<String, dynamic>>.from(
        currentList.map((e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>)),
      );

      updatedList.removeWhere((element) => element['guestName'] == guestName);

      await client.from('watchparties').update({
        'sdp_answers': updatedList,
        'current_guest_count': updatedList.length,
      }).eq('host_name', hostName);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SupabaseWatchPartyDatabase leaveLobby error: $e');
      }
    }
  }

  List<dynamic> _parseSdpAnswers(dynamic raw) {
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
