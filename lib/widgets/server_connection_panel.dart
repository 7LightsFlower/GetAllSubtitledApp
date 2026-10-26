// server_connection_panel.dart
//
// Server switcher + Connect / Token controls, shown at the top of every
// page (Simple and Expert mode alike). One shared component instead of
// a copy per screen.
//
// Pages that need to react (reload a list, reset a session id, enable
// the mic button) listen to [ServerConnection.serverChanged] and
// [ServerConnection.tokenChanged]; both fire app-wide, so a token pasted
// on one page also updates the pages underneath it in the navigator.

import 'dart:js_interop';

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/services/server_config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

/// App-wide connection events.
class ServerConnection {
  ServerConnection._();

  /// Current internal server URL; changes when the user switches.
  static final ValueNotifier<String> serverChanged =
      ValueNotifier<String>(internalServerUrl);

  /// Bumped whenever the token is set, cleared or refreshed.
  static final ValueNotifier<int> tokenChanged = ValueNotifier<int>(0);

  static Future<bool> isConnected() async {
    final token = await InternalAuthService.getToken();
    return token != null && token.isNotEmpty;
  }

  static void notifyTokenChanged() => tokenChanged.value++;
}

class ServerConnectionPanel extends StatefulWidget {
  const ServerConnectionPanel({super.key, this.enabled = true});

  /// False while something must not switch server (e.g. a running live
  /// session). The panel stays visible but greyed out.
  final bool enabled;

  @override
  State<ServerConnectionPanel> createState() => _ServerConnectionPanelState();
}

class _ServerConnectionPanelState extends State<ServerConnectionPanel> {
  bool _isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _showTokenInput = false;
  bool _showBookmarklet = false;
  final TextEditingController _tokenController = TextEditingController();
  String _tokenStatus = '';

  // Bookmarklet: one click on the /gettoken page copies the token.
  static const String _bookmarkletJs =
      "javascript:(function(){"
      "const pre=document.querySelector('pre');"
      "if(!pre){alert('Not on the /gettoken page');return;}"
      "const t=pre.textContent.trim();"
      "navigator.clipboard.writeText(t).then("
      "()=>alert('Token copied — go back to the app and click \"Paste Token\"'),"
      "()=>prompt('Copy manually:',t)"
      ");"
      "})();";

  @override
  void initState() {
    super.initState();
    ServerConnection.tokenChanged.addListener(_refresh);
    ServerConnection.serverChanged.addListener(_refresh);
    _init();
  }

  Future<void> _init() async {
    await ServerConfigService.load();
    if (ServerConnection.serverChanged.value != internalServerUrl) {
      ServerConnection.serverChanged.value = internalServerUrl;
    }
    await _refresh();
  }

  @override
  void dispose() {
    ServerConnection.tokenChanged.removeListener(_refresh);
    ServerConnection.serverChanged.removeListener(_refresh);
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final connected = await ServerConnection.isConnected();
    if (mounted) setState(() => _isConnected = connected);
  }

  void _snack(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ACTIONS
  // ═══════════════════════════════════════════════════════════════════
  Future<void> _changeServer(String url) async {
    if (url == internalServerUrl) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch internal server?'),
        content: Text(
          'Switch to:\n$url\n\n'
          'Tokens and sessions you created on the previous server may no '
          'longer work. You will likely need to reconnect and paste a new '
          'token.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ServerConfigService.setServer(url);
    await ServerConfigService.load();
    // Tokens are per-server: drop the old one.
    await InternalAuthService.clearManualToken();
    if (!mounted) return;
    setState(() {
      _tokenStatus = '🔀 Switched to: $url — paste a token for this host';
      _showTokenInput = true;
    });
    ServerConnection.serverChanged.value = internalServerUrl;
    ServerConnection.notifyTokenChanged();
    _snack('Server switched to $url');
  }

  Future<void> _connectToInternal() async {
    if (_isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      final success = await InternalAuthService.loginWithOAuth();
      ServerConnection.notifyTokenChanged();
      _snack(
        success
            ? '✅ Connected to internal server!'
            : '❌ Connection failed. Please try again.',
        error: !success,
      );
    } catch (e) {
      _snack('Error: $e', error: true);
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _setManualToken() async {
    final raw = _tokenController.text;
    final token = _extractToken(raw) ?? raw.trim();
    if (token.isEmpty) {
      setState(() => _tokenStatus = '⚠️ Please enter a token');
      return;
    }
    try {
      await InternalAuthService.setManualToken(token);
      if (!mounted) return;
      setState(() {
        _tokenStatus = '✅ Token set successfully!';
        _showTokenInput = false;
        _tokenController.clear();
      });
      ServerConnection.notifyTokenChanged();
      _snack('✅ Token set manually!');
    } catch (e) {
      if (mounted) setState(() => _tokenStatus = '❌ Error: $e');
    }
  }

  Future<void> _clearManualToken() async {
    try {
      await InternalAuthService.clearManualToken();
      if (!mounted) return;
      setState(() {
        _tokenStatus = 'Token cleared';
        _tokenController.clear();
        _showTokenInput = false;
      });
      ServerConnection.notifyTokenChanged();
      _snack('Manual token cleared.');
    } catch (e) {
      if (mounted) setState(() => _tokenStatus = '❌ Error: $e');
    }
  }

  void _openTokenPage() {
    web.window.open('$internalServerUrl/gettoken', 'gettoken_tab');
    setState(() => _tokenStatus =
        '📋 Copy the token from the new tab, then click "Paste Token"');
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final text =
          (await web.window.navigator.clipboard.readText().toDart).toDart;
      if (text.isEmpty) {
        setState(() => _tokenStatus = '⚠️ Clipboard is empty');
        return;
      }
      final token = _extractToken(text);
      if (token == null || token.isEmpty) {
        setState(() => _tokenStatus = '⚠️ No token found in clipboard');
        return;
      }
      _tokenController.text = token;
      setState(() => _tokenStatus = '✅ Token extracted — saving...');
      await _setManualToken();
    } catch (e) {
      if (mounted) {
        setState(() => _tokenStatus = '⚠️ Clipboard read failed: $e');
      }
    }
  }

  void _copyBookmarklet() {
    Clipboard.setData(const ClipboardData(text: _bookmarkletJs));
    _snack('Bookmarklet copied. Create a new bookmark and paste this as its URL.');
  }

  String? _extractToken(String raw) {
    if (raw.trim().isEmpty) return null;
    final pre = RegExp(r'<pre>\s*([^<]+?)\s*</pre>', multiLine: true)
        .firstMatch(raw);
    if (pre != null) {
      final t = pre.group(1)?.trim();
      if (t != null && t.isNotEmpty) return t;
    }
    final cookie = RegExp(r"([^\s'<>|]+\|\d{10}\|[^\s'<>]+)").firstMatch(raw);
    if (cookie != null) return cookie.group(1)?.trim();
    final trimmed = raw.trim();
    return trimmed.isNotEmpty ? trimmed : null;
  }

  Future<void> _showAddServerDialog() async {
    final controller = TextEditingController(text: 'https://lt2srv-');
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.dns_outlined, color: Colors.blueGrey),
            SizedBox(width: 8),
            Text('Add internal server'),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter the base URL of an LT2SRV host. The same '
                  'pattern the backend accepts is enforced here.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://lt2srv-alice.isl.iar.kit.edu',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link),
                  ),
                  validator: (value) {
                    final raw = (value ?? '').trim();
                    if (raw.isEmpty) return 'Enter a URL';
                    if (!raw.startsWith('https://')) {
                      return 'Must start with https://';
                    }
                    if (!isAllowedInternalServer(raw)) {
                      return 'Not a recognised lt2srv host';
                    }
                    final normalised = raw.endsWith('/')
                        ? raw.substring(0, raw.length - 1)
                        : raw;
                    if (ServerConfigService.allServers.contains(normalised)) {
                      return 'Already in the list';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.blue.shade100),
                  ),
                  child: const Text(
                    'Accepted examples:\n'
                    '  https://lt2srv.iar.kit.edu\n'
                    '  https://lt2srv-backup.iar.kit.edu\n'
                    '  https://lt2srv-sscherrer.isl.iar.kit.edu\n'
                    '  https://lt2srv-alice.isl.iar.kit.edu',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Add'),
            onPressed: () {
              if (!(formKey.currentState?.validate() ?? false)) return;
              var url = controller.text.trim();
              if (url.endsWith('/')) url = url.substring(0, url.length - 1);
              Navigator.pop(ctx, url);
            },
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;

    final outcome = await ServerConfigService.addCustomServer(result);
    if (!mounted) return;
    switch (outcome) {
      case AddResult.added:
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added $result'),
            action: SnackBarAction(
              label: 'Switch to it',
              onPressed: () => _changeServer(result),
            ),
          ),
        );
      case AddResult.duplicate:
        _snack('That server is already in the list.');
      case AddResult.invalid:
        _snack('That does not look like a valid lt2srv host.');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  UI
  // ═══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      absorbing: !widget.enabled,
      child: Opacity(
        opacity: widget.enabled ? 1 : 0.5,
        child: Card(
          elevation: 1,
          margin: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildServerRow(),
                const Divider(height: 8),
                _buildConnectionRow(),
                if (_showTokenInput) _buildTokenInput(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildServerRow() {
    final narrow = _isNarrow(context);
    final allServers = ServerConfigService.allServers;
    final customSet = ServerConfigService.customServers.toSet();

    return Row(
      children: [
        const Icon(Icons.dns_outlined, size: 20, color: Colors.blueGrey),
        const SizedBox(width: 10),
        if (!narrow) ...[
          const Text(
            'Internal server',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                labelForServer(internalServerUrl),
                style: TextStyle(
                  fontSize: narrow ? 12 : 13,
                  fontWeight: narrow ? FontWeight.w600 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                internalServerUrl,
                style: TextStyle(
                  fontSize: narrow ? 9 : 10,
                  color: Colors.grey[600],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Add custom server',
          icon: const Icon(Icons.add_circle_outline, size: 20),
          onPressed: _showAddServerDialog,
        ),
        PopupMenuButton<String>(
          tooltip: 'Switch server',
          icon: const Icon(Icons.swap_horiz, size: 20),
          onSelected: (value) async {
            if (value == '__add__') {
              await _showAddServerDialog();
            } else {
              await _changeServer(value);
            }
          },
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            for (final url in allServers)
              PopupMenuItem<String>(
                value: url,
                child: Row(
                  children: [
                    Icon(
                      url == internalServerUrl
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color:
                          url == internalServerUrl ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  labelForServer(url),
                                  style: TextStyle(
                                    fontWeight: url == internalServerUrl
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (customSet.contains(url)) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.teal.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                    border:
                                        Border.all(color: Colors.teal.shade200),
                                  ),
                                  child: Text(
                                    'custom',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: Colors.teal.shade800,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          Text(
                            url,
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey[600]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (customSet.contains(url))
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () async {
                          await ServerConfigService.removeCustomServer(url);
                          if (!mounted) return;
                          setState(() {});
                        },
                      ),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: '__add__',
              child: Row(
                children: [
                  Icon(Icons.add, size: 18, color: Colors.blue),
                  SizedBox(width: 8),
                  Text('Add server…', style: TextStyle(color: Colors.blue)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConnectionRow() {
    final narrow = _isNarrow(context);
    return Row(
      children: [
        Icon(
          _isConnected ? Icons.check_circle : Icons.info_outline,
          size: 20,
          color: _isConnected ? Colors.green : Colors.orange,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _isConnected
                ? 'Connected'
                : (narrow ? 'Not connected' : 'Not connected — connect or paste a token'),
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: _isConnected ? Colors.green : Colors.orange.shade800,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton.icon(
          onPressed: () => setState(() {
            _showTokenInput = !_showTokenInput;
            if (!_showTokenInput) {
              _tokenStatus = '';
              _tokenController.clear();
              _showBookmarklet = false;
            }
          }),
          icon: Icon(
            _showTokenInput ? Icons.keyboard_arrow_up : Icons.vpn_key,
            size: 18,
          ),
          label: Text(_showTokenInput
              ? (narrow ? 'Hide' : 'Hide Token')
              : (narrow ? 'Token' : 'Manual Token')),
          style: TextButton.styleFrom(foregroundColor: Colors.blue),
        ),
        IconButton(
          onPressed: _isConnecting ? null : _connectToInternal,
          tooltip: _isConnected ? 'Reconnect' : 'Connect',
          icon: _isConnecting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_isConnected ? Icons.link : Icons.link_off),
        ),
      ],
    );
  }

  Widget _buildTokenInput() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 6, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber[50],
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber[200]!),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lightbulb_outline,
                    size: 18, color: Colors.amber[800]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '1. Click "Get Token" → new tab opens.\n'
                    '2. On that tab press Ctrl+A then Ctrl+C.\n'
                    '3. Come back and click "Paste Token".',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.amber[900],
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tokenController,
            decoration: InputDecoration(
              hintText: 'Token will appear here after pasting...',
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              errorText: _tokenStatus.contains('❌') ? _tokenStatus : null,
              helperText: _tokenStatus.contains('✅') ? _tokenStatus : null,
              helperStyle: const TextStyle(color: Colors.green),
              suffixIcon: _tokenController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => _tokenController.clear()),
                    )
                  : null,
            ),
            maxLines: 2,
            minLines: 1,
            onChanged: (_) {
              if (_tokenStatus.isNotEmpty && !_tokenStatus.startsWith('📋')) {
                setState(() => _tokenStatus = '');
              }
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openTokenPage,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Get Token'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blue,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('Paste Token'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _setManualToken,
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('Set Manually'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _clearManualToken,
                icon: const Icon(Icons.clear, size: 18),
                label: const Text('Clear'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                ),
              ),
            ],
          ),
          if (_tokenStatus.isNotEmpty &&
              !_tokenStatus.contains('❌') &&
              !_tokenStatus.contains('✅'))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _tokenStatus,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => setState(() => _showBookmarklet = !_showBookmarklet),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _showBookmarklet
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: Colors.blueGrey,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Power-user tip: one-click copy bookmarklet',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blueGrey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_showBookmarklet)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                color: Colors.blueGrey[50],
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.blueGrey[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Create a bookmark whose URL is the text below. Then on '
                    'the /gettoken page, click it once to copy the token.',
                    style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.blueGrey[100]!),
                    ),
                    child: const SelectableText(
                      _bookmarkletJs,
                      style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _copyBookmarklet,
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Bookmarklet'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blueGrey[800],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
