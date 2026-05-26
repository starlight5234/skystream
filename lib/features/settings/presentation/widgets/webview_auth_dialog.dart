import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../shared/widgets/custom_widgets.dart';

class WebViewAuthDialog extends StatefulWidget {
  final String providerName;
  final String initialUrl;
  final String redirectUrlPrefix;

  const WebViewAuthDialog({
    super.key,
    required this.providerName,
    required this.initialUrl,
    required this.redirectUrlPrefix,
  });

  @override
  State<WebViewAuthDialog> createState() => _WebViewAuthDialogState();
}

class _WebViewAuthDialogState extends State<WebViewAuthDialog> {
  InAppWebViewController? webViewController;
  double progress = 0;
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Avoid flutter_inappwebview on Windows/Linux as they are not fully supported
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      return _buildDesktopFallback(context);
    }
    return _buildWebView(context);
  }

  Widget _buildDesktopFallback(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text('Login to ${widget.providerName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '1. Click the button below to open the login page in your browser.',
            ),
            const SizedBox(height: 16),
            CustomButton(
              isPrimary: true,
              onPressed: () async {
                final uri = Uri.parse(widget.initialUrl);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: const Text('Open Browser'),
            ),
            const SizedBox(height: 24),
            Text(
              '2. After logging in, the browser will redirect you to a blank page starting with ${widget.redirectUrlPrefix}.',
            ),
            const SizedBox(height: 8),
            const Text(
              '3. Copy the ENTIRE URL from your browser\'s address bar and paste it below:',
            ),
            const SizedBox(height: 16),
            CustomTextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Pasted Redirect URL',
                hintText: 'http://localhost/?code=...',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        CustomButton(
          isPrimary: true,
          onPressed: () {
            final url = _urlController.text.trim();
            if (url.isNotEmpty) {
              Navigator.pop(context, url);
            }
          },
          child: const Text('Submit'),
        ),
      ],
    );
  }

  Widget _buildWebView(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 800,
          height: 600,
          child: Column(
            children: [
              AppBar(
                title: Text('Login to ${widget.providerName}'),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
                elevation: 0,
              ),
              if (progress < 1.0)
                LinearProgressIndicator(value: progress),
              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
                  onWebViewCreated: (controller) {
                    webViewController = controller;
                  },
                  onLoadStart: (controller, url) {
                    if (url != null && url.toString().startsWith(widget.redirectUrlPrefix)) {
                      Navigator.pop(context, url.toString());
                    }
                  },
                  onProgressChanged: (controller, progress) {
                    setState(() {
                      this.progress = progress / 100;
                    });
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
