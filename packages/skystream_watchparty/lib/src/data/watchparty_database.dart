abstract class WatchPartyDatabase {
  Future<void> createLobby({
    required String hostName,
    required String deviceType,
    required int maxGuests,
    required String passcodeHash,
  });

  Future<void> deleteLobby({
    required String hostName,
    required String passcodeHash,
  });

  Future<void> leaveLobby({required String hostName, required String guestName});

  Future<void> joinLobby({
    required String hostName,
    required String guestName,
    required String sdpOffer,
    required String passcodeHash,
  });

  Future<void> respondToLobby({
    required String hostName,
    required String guestName,
    required String sdpAnswer,
  });

  Stream<Map<String, dynamic>?> subscribeToLobby({required String hostName});

  Future<Map<String, dynamic>?> getLobby({required String hostName});

  bool isConfigured();
}
