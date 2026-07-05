abstract class WatchPartyDatabase {
  Future<void> createLobby({
    required String hostName,
    required String deviceType,
    required int maxGuests,
    required String sdpOffer,
  });

  Future<void> deleteLobby({required String hostName});

  Future<void> leaveLobby({required String hostName, required String guestName});

  Future<void> joinLobby({
    required String hostName,
    required String guestName,
    required String sdpAnswer,
  });

  Stream<Map<String, dynamic>?> subscribeToLobby({required String hostName});

  Future<Map<String, dynamic>?> getLobby({required String hostName});

  bool isConfigured();
}
