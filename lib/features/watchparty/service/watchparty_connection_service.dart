import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import '../../settings/presentation/general_settings_provider.dart';
import 'webrtc_connection_manager.dart';

abstract class WatchPartyConnectionService extends ChangeNotifier {
  final GeneralSettings settings;
  final WatchPartyDatabase database;

  bool _isLoading = false;
  String _statusMessage = '';
  String? _error;
  bool _connectionSuccess = false;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  final List<String> _diagnosticLogs = [];

  // Track candidate counts
  int _localHostCount = 0;
  int _localSrflxCount = 0;
  int _localRelayCount = 0;
  int _remoteHostCount = 0;
  int _remoteSrflxCount = 0;
  int _remoteRelayCount = 0;
  String _currentIceConnectionState = 'new';
  String _currentIceGatheringState = 'new';
  String _currentSignalingState = 'stable';
  Completer<void>? _iceGatheringCompleter;

  WatchPartyConnectionService(this.settings, this.database);

  // Getters for UI state
  bool get isLoading => _isLoading;
  String get statusMessage => _statusMessage;
  String? get error => _error;
  bool get connectionSuccess => _connectionSuccess;
  List<String> get diagnosticLogs => _diagnosticLogs;
  RTCPeerConnection? get peerConnection => _peerConnection;
  RTCDataChannel? get dataChannel => _dataChannel;

  int get localHostCount => _localHostCount;
  int get localSrflxCount => _localSrflxCount;
  int get localRelayCount => _localRelayCount;
  int get remoteHostCount => _remoteHostCount;
  int get remoteSrflxCount => _remoteSrflxCount;
  int get remoteRelayCount => _remoteRelayCount;
  String get currentIceConnectionState => _currentIceConnectionState;
  String get currentIceGatheringState => _currentIceGatheringState;
  String get currentSignalingState => _currentSignalingState;

  // Setters for subclasses to modify state and notify UI
  set isLoading(bool val) {
    _isLoading = val;
    notifyListeners();
  }

  set statusMessage(String val) {
    _statusMessage = val;
    notifyListeners();
  }

  set error(String? val) {
    _error = val;
    if (val != null) {
      _isLoading = false;
    }
    notifyListeners();
  }

  set connectionSuccess(bool val) {
    _connectionSuccess = val;
    notifyListeners();
  }

  set peerConnection(RTCPeerConnection? val) {
    _peerConnection = val;
  }

  set dataChannel(RTCDataChannel? val) {
    _dataChannel = val;
  }

  void logMessage(String msg) {
    final timestamp = DateTime.now().toString().split(' ').last.substring(0, 8);
    _diagnosticLogs.add('$timestamp - $msg');
    if (kDebugMode) {
      debugPrint('[WatchParty] $msg');
    }
    notifyListeners();
  }

  Future<void> waitForIceGatheringCompletion({Duration timeout = const Duration(seconds: 10)}) async {
    if (_currentIceGatheringState == 'RTCIceGatheringStateComplete') {
      logMessage('ICE Gathering is already complete.');
      return;
    }
    _iceGatheringCompleter = Completer<void>();
    logMessage('Waiting for ICE gathering completeness signal (timeout: ${timeout.inSeconds}s)...');
    try {
      await _iceGatheringCompleter!.future.timeout(timeout);
      logMessage('ICE gathering completed successfully.');
    } catch (_) {
      logMessage('ICE gathering wait window expired.');
    } finally {
      _iceGatheringCompleter = null;
    }
  }

  void setupConnectionListeners(RTCPeerConnection pc) {
    pc.onIceConnectionState = (state) {
      _currentIceConnectionState = state.toString().split('.').last;
      logMessage('ICE Connection State: $_currentIceConnectionState');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        logMessage('ICE Connection failed definitively.');
        error = 'ICE Connection failed. Peer connection could not be established.\n\n'
            'Please verify your TURN server configuration credentials in settings if you are connecting across separate networks.';
        cleanup();
      }
      notifyListeners();
    };

    pc.onSignalingState = (state) {
      _currentSignalingState = state.toString().split('.').last;
      logMessage('Signaling State: $_currentSignalingState');
      notifyListeners();
    };

    pc.onIceGatheringState = (state) {
      _currentIceGatheringState = state.toString().split('.').last;
      logMessage('ICE Gathering State: $_currentIceGatheringState');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (_iceGatheringCompleter != null && !_iceGatheringCompleter!.isCompleted) {
          _iceGatheringCompleter!.complete();
        }
      }
      notifyListeners();
    };

    pc.onIceCandidate = (candidate) {
      if (candidate == null) {
        logMessage('Gathered candidate: gathering complete (null)');
        return;
      }
      
      final cand = candidate.candidate ?? '';
      String type = 'unknown';
      if (cand.contains('typ host')) {
        type = 'Host';
      } else if (cand.contains('typ srflx')) {
        type = 'STUN';
      } else if (cand.contains('typ relay')) {
        type = 'TURN';
      }
      logMessage('Gathered candidate: type=$type');
    };
  }

  void setupDataChannelListeners(RTCDataChannel dc) {
    dc.onDataChannelState = (state) {
      logMessage('Data Channel State: ${state.toString().split('.').last}');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _connectionSuccess = true;
        _isLoading = false;
        logMessage('P2P Data Channel connected successfully!');
        notifyListeners();
      }
    };
  }

  void logSdpDiagnostics(String sdp, String origin) {
    final counts = WebRTCConnectionManager.parseSdpDiagnostics(sdp);
    final host = counts['host'] ?? 0;
    final srflx = counts['srflx'] ?? 0;
    final relay = counts['relay'] ?? 0;

    logMessage('$origin SDP: Host=$host, STUN=$srflx, TURN=$relay candidates.');

    if (origin == 'Local') {
      _localHostCount = host;
      _localSrflxCount = srflx;
      _localRelayCount = relay;
    } else {
      _remoteHostCount = host;
      _remoteSrflxCount = srflx;
      _remoteRelayCount = relay;
    }
    notifyListeners();
  }

  String getFailureSummary() {
    return 'ICE Server Configuration:\n'
        '  TURN User: ${settings.watchPartyTurnUsername.isNotEmpty ? "Configured" : "None"}\n'
        'ICE Connection State: $_currentIceConnectionState\n'
        'Signaling State: $_currentSignalingState\n'
        'Candidates Gathered (Local):\n'
        '  Host (LAN): $_localHostCount\n'
        '  STUN (srflx): $_localSrflxCount\n'
        '  TURN (relay): $_localRelayCount\n'
        'Candidates Received (Remote):\n'
        '  Host (LAN): $_remoteHostCount\n'
        '  STUN (srflx): $_remoteSrflxCount\n'
        '  TURN (relay): $_remoteRelayCount\n';
  }

  void resetState() {
    _isLoading = false;
    _statusMessage = '';
    _error = null;
    _connectionSuccess = false;
    _diagnosticLogs.clear();
    _currentIceConnectionState = 'new';
    _currentIceGatheringState = 'new';
    _currentSignalingState = 'stable';
    _localHostCount = 0;
    _localSrflxCount = 0;
    _localRelayCount = 0;
    _remoteHostCount = 0;
    _remoteSrflxCount = 0;
    _remoteRelayCount = 0;
    if (_iceGatheringCompleter != null && !_iceGatheringCompleter!.isCompleted) {
      _iceGatheringCompleter!.complete();
    }
    _iceGatheringCompleter = null;
    cleanup();
    notifyListeners();
  }

  void cleanup() {
    if (_iceGatheringCompleter != null && !_iceGatheringCompleter!.isCompleted) {
      _iceGatheringCompleter!.complete();
    }
    _iceGatheringCompleter = null;
    _currentIceGatheringState = 'new';
    
    if (_dataChannel != null) {
      unawaited(_dataChannel!.close());
      _dataChannel = null;
    }
    if (_peerConnection != null) {
      unawaited(_peerConnection!.dispose());
      _peerConnection = null;
    }
  }

  @override
  void dispose() {
    cleanup();
    super.dispose();
  }
}
