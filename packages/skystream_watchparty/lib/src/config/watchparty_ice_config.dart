class WatchPartyIceConfig {
  /// Verified fallback STUN servers (limited to avoid Windows native array overflow crashes)
  static const List<String> productionStunServers = [
    'stun:stun.l.google.com:19302',
    'stun:stun.relay.metered.ca:80',
  ];

  /// Standard TURN/TURNS connection templates for maximum firewall and protocol fallback compatibility
  static const List<String> turnEndpointTemplates = [
    'turn:{region}.{domain}:80',
    'turn:{region}.{domain}:80?transport=tcp',
    'turn:{region}.{domain}:443',
    'turns:{region}.{domain}:443?transport=tcp',
  ];

  /// Regional locks
  static const List<String> defaultTurnRegions = [
    'global',
  ];

  static const String defaultTurnDomain = 'relay.metered.ca';
}
