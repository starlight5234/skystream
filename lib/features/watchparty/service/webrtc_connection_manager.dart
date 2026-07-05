import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../settings/presentation/general_settings_provider.dart';
import '../config/watchparty_ice_config.dart';

class WebRTCConnectionManager {
  /// Generates the ICE Server configuration with fallback STUNs and regional TURN TCP/TLS relays.
  static Map<String, dynamic> getIceConfiguration(GeneralSettings settings) {
    final turnUser = settings.watchPartyTurnUsername.trim();
    final turnPass = settings.watchPartyTurnPassword.trim();

    final List<Map<String, dynamic>> iceServers = [];

    // 1. Standard STUN fallback servers from Config (Each in its own map of length 1)
    for (final url in WatchPartyIceConfig.productionStunServers) {
      iceServers.add({
        'urls': [url],
      });
    }

    // 2. TURN servers built from Config templates (each in its own map of length 1)
    if (turnUser.isNotEmpty && turnPass.isNotEmpty) {
      final domain = WatchPartyIceConfig.defaultTurnDomain;
      for (final r in WatchPartyIceConfig.defaultTurnRegions) {
        for (final template in WatchPartyIceConfig.turnEndpointTemplates) {
          final url = template
              .replaceAll('{region}', r)
              .replaceAll('{domain}', domain);
          iceServers.add({
            'urls': [url],
            'username': turnUser,
            'credential': turnPass,
            'password': turnPass,
          });
        }
      }
    }

    return {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };
  }

  /// Creates a peer connection with the correct ICE settings.
  static Future<RTCPeerConnection> createConnection(
    GeneralSettings settings, {
    void Function(String)? logCallback,
  }) async {
    final config = getIceConfiguration(settings);
    return await createPeerConnection(config);
  }

  /// Parses SDP payload to extract candidate counts by type.
  static Map<String, int> parseSdpDiagnostics(String sdp) {
    int host = 0;
    int srflx = 0;
    int relay = 0;

    final lines = sdp.split('\n');
    for (final line in lines) {
      if (line.trim().startsWith('a=candidate:')) {
        if (line.contains('typ host')) {
          host++;
        } else if (line.contains('typ srflx')) {
          srflx++;
        } else if (line.contains('typ relay')) {
          relay++;
        }
      }
    }

    return {
      'host': host,
      'srflx': srflx,
      'relay': relay,
    };
  }
}
