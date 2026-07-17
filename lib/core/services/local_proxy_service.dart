import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';

class ProxyOptions {
  final List<String> mirrorHosts;
  final List<String> keepCookies;
  final String? referer;

  ProxyOptions({
    this.mirrorHosts = const [],
    this.keepCookies = const [],
    this.referer,
  });

  factory ProxyOptions.fromJson(Map<String, dynamic> json) {
    return ProxyOptions(
      mirrorHosts:
          (json['mirrorHosts'] as List?)?.map((e) => e.toString()).toList() ??
          [],
      keepCookies:
          (json['keepCookies'] as List?)?.map((e) => e.toString()).toList() ??
          [],
      referer: json['referer']?.toString(),
    );
  }
}

class LocalProxyService {
  static final LocalProxyService _instance = LocalProxyService._internal();

  static LocalProxyService get instance => _instance;

  LocalProxyService._internal();

  Isolate? _isolate;
  SendPort? _commandPort;
  int _serverPort = 0;
  final Map<String, String> _playlists = {};

  static const int _maxPlaylists = 50;

  int get port => _serverPort;

  Future<void> startServer() async {
    if (_isolate != null) return;
    final receivePort = ReceivePort();
    
    // Spawn background isolate
    _isolate = await Isolate.spawn(_proxyIsolateEntry, receivePort.sendPort);

    // Wait for the isolate to start and return the configuration
    final completer = Completer<void>();
    receivePort.listen((message) {
      if (message is Map && message['type'] == 'started') {
        _serverPort = message['port'] as int;
        _commandPort = message['commandPort'] as SendPort;
        
        // Re-register any pre-existing playlists (if any)
        _playlists.forEach((uuid, content) {
          _commandPort?.send({
            'type': 'add_playlist',
            'uuid': uuid,
            'content': content,
          });
        });
        
        completer.complete();
      }
    });
    await completer.future;
    receivePort.close();
  }

  Future<void> shutdown() async {
    _commandPort?.send({'type': 'shutdown'});
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _commandPort = null;
    _serverPort = 0;
    _playlists.clear();
  }

  String serveM3u8(String content) {
    if (_isolate == null) {
      startServer();
    }

    // Evict oldest entries if at capacity
    while (_playlists.length >= _maxPlaylists) {
      final oldestKey = _playlists.keys.first;
      _playlists.remove(oldestKey);
      _commandPort?.send({
        'type': 'remove_playlist',
        'uuid': oldestKey,
      });
    }

    final uuid =
        "${DateTime.now().millisecondsSinceEpoch}_${(content.length % 1000)}";
    _playlists[uuid] = content;
    
    _commandPort?.send({
      'type': 'add_playlist',
      'uuid': uuid,
      'content': content,
    });
    
    return "http://127.0.0.1:$_serverPort/$uuid.m3u8";
  }

  String getProxyUrl(
    String targetUrl, {
    Map<String, String>? headers,
    ProxyOptions? options,
    bool forceM3u8Extension = false,
  }) {
    if (_isolate == null) {
      startServer();
    }
    final encoded = Uri.encodeComponent(targetUrl);
    String url = "http://127.0.0.1:$_serverPort/proxy?url=$encoded";

    if (headers != null && headers.isNotEmpty) {
      final headerJson = jsonEncode(headers);
      final headerB64 = base64Url.encode(utf8.encode(headerJson));
      url += "&h=$headerB64";
    }

    if (options != null) {
      final optJson = jsonEncode({
        'mirrorHosts': options.mirrorHosts,
        'keepCookies': options.keepCookies,
        'referer': options.referer,
      });
      final optB64 = base64Url.encode(utf8.encode(optJson));
      url += "&o=$optB64";
    }

    if (forceM3u8Extension) {
      url += "&extension=.m3u8";
    }

    return url;
  }

  // -------------------------------------------------------------
  // ISOLATE ENTRYPOINT AND LOGIC
  // -------------------------------------------------------------
  
  static void _proxyIsolateEntry(SendPort mainSendPort) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    final commandPort = ReceivePort();
    mainSendPort.send({
      'type': 'started',
      'port': port,
      'commandPort': commandPort.sendPort,
    });

    final Map<String, String> playlists = {};

    commandPort.listen((message) async {
      if (message is Map) {
        final type = message['type'];
        if (type == 'add_playlist') {
          final uuid = message['uuid'];
          final content = message['content'];
          playlists[uuid] = content;
        } else if (type == 'remove_playlist') {
          final uuid = message['uuid'];
          playlists.remove(uuid);
        } else if (type == 'shutdown') {
          await server.close(force: true);
          commandPort.close();
        }
      }
    });

    await for (final request in server) {
      try {
        if (!request.connectionInfo!.remoteAddress.isLoopback) {
          request.response.statusCode = HttpStatus.forbidden;
          unawaited(request.response.close());
          continue;
        }

        final path = request.uri.path;

        if (path == '/proxy') {
          await _isolateHandleProxyRequest(request, port);
        } else if (path.length > 1 && path.endsWith('.m3u8')) {
          final uuid = path.substring(1).replaceAll(".m3u8", "");
          if (playlists.containsKey(uuid)) {
            final content = playlists[uuid]!;
            request.response.headers.contentType = ContentType(
              "application",
              "vnd.apple.mpegurl",
              charset: "utf-8",
            );
            request.response.headers.add(
              "Access-Control-Allow-Origin",
              "http://127.0.0.1:$port",
            );
            request.response.add(utf8.encode(content));
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          unawaited(request.response.close());
        } else {
          request.response.statusCode = HttpStatus.notFound;
          unawaited(request.response.close());
        }
      } catch (e) {
        if (kDebugMode) debugPrint("LocalProxyService Isolate Error: $e");
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          unawaited(request.response.close());
        } catch (_) {}
      }
    }
  }

  static bool _isProxyableUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (!uri.hasScheme) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    return true;
  }

  static Future<void> _isolateHandleProxyRequest(HttpRequest request, int serverPort) async {
    final targetUrl = request.uri.queryParameters['url'];
    if (targetUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      unawaited(request.response.close());
      return;
    }

    if (!_isProxyableUrl(targetUrl)) {
      if (kDebugMode) {
        debugPrint("[PROXY] Rejecting non-proxyable URL: $targetUrl");
      }
      request.response.statusCode = HttpStatus.badRequest;
      unawaited(request.response.close());
      return;
    }

    if (kDebugMode) debugPrint("[PROXY] Incoming Request for: $targetUrl");

    final Map<String, String> stickyHeaders = {};
    final hBase64 = request.uri.queryParameters['h'];
    if (hBase64 != null) {
      try {
        final decoded = utf8.decode(base64Url.decode(hBase64));
        final Map<String, dynamic> map =
            jsonDecode(decoded) as Map<String, dynamic>;
        map.forEach((key, value) => stickyHeaders[key] = value.toString());
      } catch (e) {
        if (kDebugMode) {
          debugPrint("[PROXY] Failed to parse sticky headers: $e");
        }
      }
    }

    ProxyOptions? options;
    final oBase64 = request.uri.queryParameters['o'];
    if (oBase64 != null) {
      try {
        final decoded = utf8.decode(base64Url.decode(oBase64));
        options = ProxyOptions.fromJson(
          jsonDecode(decoded) as Map<String, dynamic>,
        );
      } catch (e) {
        if (kDebugMode) debugPrint("[PROXY] Failed to parse options: $e");
      }
    }

    final isRequestM3u8 = targetUrl.toLowerCase().contains(".m3u8");

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    client.idleTimeout = const Duration(seconds: 30);
    client.autoUncompress = isRequestM3u8;
    client.badCertificateCallback = (cert, host, port) => true;

    try {
      final req = await client.getUrl(Uri.parse(targetUrl));

      final Map<String, String> mergedCookies = {};
      request.headers.forEach((name, values) {
        final lowerName = name.toLowerCase();
        if (lowerName == 'cookie') {
          for (final v in values) {
            for (final pair in v.split(';')) {
              final parts = pair.split('=');
              if (parts.length >= 2) {
                mergedCookies[parts[0].trim()] = parts
                    .sublist(1)
                    .join('=')
                    .trim();
              }
            }
          }
        } else if (lowerName == 'range' && isRequestM3u8) {
          // Skip Range header for M3U8
        } else if (lowerName != 'host' &&
            lowerName != 'content-length' &&
            lowerName != 'connection' &&
            lowerName != 'accept-encoding' &&
            lowerName != 'referer' &&
            lowerName != 'user-agent' &&
            lowerName != 'icy-metadata') {
          for (final value in values) {
            req.headers.add(name, value);
          }
        }
      });

      stickyHeaders.forEach((name, value) {
        final lowerName = name.toLowerCase();
        if (lowerName == 'cookie') {
          for (final pair in value.split(';')) {
            final parts = pair.split('=');
            if (parts.length >= 2) {
              mergedCookies[parts[0].trim()] = parts
                  .sublist(1)
                  .join('=')
                  .trim();
            }
          }
        } else {
          req.headers.set(name, value);
        }
      });

      if (mergedCookies.isNotEmpty) {
        final cookieString = mergedCookies.entries
            .map((e) => "${e.key}=${e.value}")
            .join("; ");
        req.headers.set("Cookie", cookieString);
      }

      _applySanitizedHeaders(req, targetUrl, options);

      req.headers.set('accept-encoding', 'identity');

      if (kDebugMode) {
        final rangeHeader = req.headers.value('range');
        if (rangeHeader != null) {
          debugPrint('[PROXY] Range request: $rangeHeader → $targetUrl');
        }
      }
      final response = await _fetchWithRedirects(
        client,
        req,
        targetUrl,
        options,
      );

      final isResponseM3u8 = _isM3u8(
        response.headers.contentType?.mimeType,
        targetUrl,
      );

      final hasChunkedEncoding =
          response.headers
              .value('transfer-encoding')
              ?.toLowerCase()
              .contains('chunked') ==
          true;
      final hasContentRange = response.headers.value('content-range') != null;
      final hasContentLength = response.headers.value('content-length') != null;
      final misleadingContentRange =
          !isResponseM3u8 &&
          response.statusCode == 206 &&
          hasChunkedEncoding &&
          hasContentRange &&
          !hasContentLength;

      request.response.statusCode =
          (isResponseM3u8 &&
              (response.statusCode == 200 || response.statusCode == 206))
          ? 200
          : (misleadingContentRange ? 200 : response.statusCode);

      // Copy response headers
      response.headers.forEach((name, values) {
        final lowerName = name.toLowerCase();
        if (lowerName != 'content-length' &&
            lowerName != 'content-encoding' &&
            lowerName != 'transfer-encoding' &&
            lowerName != 'access-control-allow-origin') {
          for (final value in values) {
            request.response.headers.add(name, value);
          }
        }
      });

      if (response.headers.value('content-encoding')?.contains('gzip') == true &&
          !isResponseM3u8) {
        // Gzipped binary payload (copy accurate content length if known, or chunked)
      } else if (!isResponseM3u8 && !misleadingContentRange) {
        final contentLength = response.headers.value('content-length');
        if (contentLength != null) {
          request.response.headers.set('content-length', contentLength);
        }
      }

      request.response.headers.add(
        "Access-Control-Allow-Origin",
        "http://127.0.0.1:$serverPort",
      );

      if (isResponseM3u8 &&
          (response.statusCode == 200 || response.statusCode == 206)) {
        await _isolateRewriteM3u8Response(
          response,
          request,
          targetUrl,
          stickyHeaders,
          options,
          serverPort,
        );
      } else {
        await response.pipe(request.response);
      }
    } catch (e) {
      if (kDebugMode) debugPrint("LocalProxyService: Proxy Request Error: $e");
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    }
  }

  static void _applySanitizedHeaders(
    HttpClientRequest req,
    String targetUrl,
    ProxyOptions? options,
  ) {
    if (req.headers['User-Agent'] == null) {
      req.headers.set("User-Agent", "Mozilla/5.0 (Android) ExoPlayer");
    }

    final existingReferer = req.headers['Referer']?.join("");
    if (existingReferer == null || existingReferer.contains("127.0.0.1")) {
      final uri = Uri.parse(targetUrl);
      final optReferer = options?.referer;
      if (optReferer != null) {
        req.headers.set("Referer", optReferer);
      } else {
        req.headers.set("Referer", "${uri.scheme}://${uri.host}/");
      }
    }

    final targetUri = Uri.parse(targetUrl);
    bool isMirrorSite = false;
    if (options != null) {
      isMirrorSite = options.mirrorHosts.any(
        (host) => targetUri.host.contains(host),
      );
    }

    if (!isMirrorSite) {
      final currentCookies = req.headers['Cookie']?.join("; ") ?? "";
      if (options != null && options.keepCookies.isNotEmpty) {
        final filtered = currentCookies
            .split(';')
            .map((s) => s.trim())
            .where((s) {
              final key = s.split('=')[0];
              return options.keepCookies.contains(key);
            })
            .join("; ");
        if (filtered.isNotEmpty) {
          req.headers.set("Cookie", filtered);
        } else {
          req.headers.removeAll("Cookie");
        }
      } else {
        req.headers.removeAll("Cookie");
      }
    }

    if (options != null && options.keepCookies.contains("hd")) {
      final finalCookies = req.headers['Cookie']?.join("; ") ?? "";
      if (!finalCookies.contains("hd=on")) {
        if (finalCookies.isEmpty) {
          req.headers.set("Cookie", "hd=on");
        } else {
          req.headers.set("Cookie", "$finalCookies; hd=on");
        }
      }
    }
  }

  static Future<HttpClientResponse> _fetchWithRedirects(
    HttpClient client,
    HttpClientRequest initialRequest,
    String currentUrl,
    ProxyOptions? options,
  ) async {
    HttpClientRequest currentReq = initialRequest;
    currentReq.followRedirects = false;

    int redirectCount = 0;
    const maxRedirects = 5;

    while (redirectCount < maxRedirects) {
      final response = await currentReq.close();

      if (response.statusCode == HttpStatus.movedPermanently ||
          response.statusCode == HttpStatus.found ||
          response.statusCode == HttpStatus.seeOther ||
          response.statusCode == HttpStatus.temporaryRedirect ||
          response.statusCode == HttpStatus.permanentRedirect) {
        final location = response.headers.value('location');
        if (location == null) return response;

        final nextUrl = Uri.parse(currentUrl).resolve(location).toString();
        redirectCount++;

        final nextReq = await client.getUrl(Uri.parse(nextUrl));
        nextReq.followRedirects = false;

        initialRequest.headers.forEach((name, values) {
          final lowerName = name.toLowerCase();
          if (lowerName != 'host' &&
              lowerName != 'content-length' &&
              lowerName != 'connection') {
            for (final v in values) {
              nextReq.headers.add(name, v);
            }
          }
        });

        _applySanitizedHeaders(nextReq, nextUrl, options);

        currentReq = nextReq;
        currentUrl = nextUrl;
      } else {
        return response;
      }
    }

    throw Exception("Too many redirects");
  }

  static bool _isM3u8(String? mimeType, String url) {
    final lowerUrl = url.toLowerCase();
    return (mimeType == "application/vnd.apple.mpegurl" ||
        mimeType == "application/x-mpegurl" ||
        mimeType == "audio/x-mpegurl" ||
        mimeType == "video/x-mpegurl" ||
        lowerUrl.contains(".m3u8") ||
        lowerUrl.contains(".m3u") ||
        lowerUrl.contains("play.php") ||
        lowerUrl.contains("index.php") ||
        lowerUrl.contains("playlist.php"));
  }

  static Future<void> _isolateRewriteM3u8Response(
    HttpClientResponse sourceResponse,
    HttpRequest clientRequest,
    String originalUrl,
    Map<String, String> stickyHeaders,
    ProxyOptions? options,
    int serverPort,
  ) async {
    final contentBytes = await sourceResponse.toList();
    final allBytes = contentBytes.expand((x) => x).toList();

    if (!_isValidM3u8(allBytes)) {
      clientRequest.response.add(allBytes);
      await clientRequest.response.close();
      return;
    }

    final content = utf8.decode(allBytes, allowMalformed: true);
    final baseUrl = Uri.parse(originalUrl);

    final rewritten = content
        .split('\n')
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return line;

          if (trimmed.startsWith("#")) {
            if (trimmed.contains('URI="')) {
              return trimmed.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (
                match,
              ) {
                final uri = match.group(1)!;
                final r = _isolateRewriteUrl(uri, baseUrl, stickyHeaders, options, serverPort);
                return 'URI="$r"';
              });
            }
            return line;
          }

          return _isolateRewriteUrl(
            trimmed,
            baseUrl,
            stickyHeaders,
            options,
            serverPort,
            isSegment: true,
          );
        })
        .join('\n');

    clientRequest.response.add(utf8.encode(rewritten));
    await clientRequest.response.close();
  }

  static bool _isValidM3u8(List<int> bytes) {
    try {
      if (bytes.length > 4) {
        final content = utf8
            .decode(bytes.take(50).toList(), allowMalformed: true)
            .trim();
        return content.contains("#EXT");
      }
    } catch (_) {}
    return false;
  }

  static String _isolateRewriteUrl(
    String uri,
    Uri baseUrl,
    Map<String, String> stickyHeaders,
    ProxyOptions? options,
    int serverPort, {
    bool isSegment = false,
  }) {
    try {
      Uri resolved = baseUrl.resolve(uri);

      bool isHostMatch = false;
      if (options != null) {
        isHostMatch = options.mirrorHosts.any(
          (host) => resolved.host.contains(host),
        );
      }

      if (resolved.query.isEmpty &&
          baseUrl.query.isNotEmpty &&
          (resolved.host == baseUrl.host || isHostMatch)) {
        resolved = resolved.replace(query: baseUrl.query);
      }
      
      final encoded = Uri.encodeComponent(resolved.toString());
      String url = "http://127.0.0.1:$serverPort/proxy?url=$encoded";

      if (stickyHeaders.isNotEmpty) {
        final headerJson = jsonEncode(stickyHeaders);
        final headerB64 = base64Url.encode(utf8.encode(headerJson));
        url += "&h=$headerB64";
      }

      if (options != null) {
        final optJson = jsonEncode({
          'mirrorHosts': options.mirrorHosts,
          'keepCookies': options.keepCookies,
          'referer': options.referer,
        });
        final optB64 = base64Url.encode(utf8.encode(optJson));
        url += "&o=$optB64";
      }

      return isSegment ? '$url&_ext=.ts' : url;
    } catch (e) {
      return uri;
    }
  }
}
