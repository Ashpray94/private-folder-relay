import 'dart:async';
import 'dart:convert';
import 'dart:io';

final groups = <String, Map<String, WebSocket>>{};

Future<void> main(List<String> args) async {
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final requiredToken = Platform.environment['RELAY_TOKEN'];
  if (requiredToken != null && requiredToken.length < 32) {
    stderr.writeln('RELAY_TOKEN must contain at least 32 characters.');
    exitCode = 64;
    return;
  }
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('Private Folder relay listening on $port');
  await for (final request in server) {
    unawaited(_handle(request, requiredToken));
  }
}

Future<void> _handle(HttpRequest request, String? requiredToken) async {
  if (request.method == 'GET' && request.uri.path == '/health') {
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true, 'connections': _connectionCount()}));
    await request.response.close();
    return;
  }
  if (request.uri.path != '/v1/connect' ||
      !WebSocketTransformer.isUpgradeRequest(request)) {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
    return;
  }
  final auth = request.headers.value(HttpHeaders.authorizationHeader);
  final token = auth?.startsWith('Bearer ') == true ? auth!.substring(7) : '';
  final device = request.uri.queryParameters['device'] ?? '';
  if (token.length < 32 ||
      (requiredToken != null && token != requiredToken) ||
      !RegExp(r'^[A-Za-z0-9_-]{20,32}={0,2}$').hasMatch(device)) {
    request.response.statusCode = HttpStatus.unauthorized;
    await request.response.close();
    return;
  }
  final socket = await WebSocketTransformer.upgrade(request);
  socket.pingInterval = const Duration(seconds: 25);
  final members = groups.putIfAbsent(token, () => {});
  await members[device]?.close(
    WebSocketStatus.policyViolation,
    'Device connected elsewhere',
  );
  for (final existing in members.keys) {
    if (existing != device) {
      socket.add(
        jsonEncode({'type': 'presence', 'device': existing, 'online': true}),
      );
    }
  }
  members[device] = socket;
  _broadcastPresence(token, device, true, except: device);
  socket.listen(
    (raw) => _route(token, device, socket, raw),
    onDone: () => _remove(token, device, socket),
    onError: (_) => _remove(token, device, socket),
    cancelOnError: true,
  );
}

void _route(String token, String sender, WebSocket source, Object? raw) {
  if (raw is! String || raw.length > 12 * 1024 * 1024) {
    source.close(WebSocketStatus.messageTooBig, 'Frame too large');
    return;
  }
  try {
    final frame = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final type = frame['type'];
    final recipient = frame['to'];
    final request = frame['request'];
    if ((type != 'request' && type != 'response') ||
        recipient is! String ||
        request is! String ||
        request.length > 128) {
      throw const FormatException('Invalid frame');
    }
    final target = groups[token]?[recipient];
    if (target == null || target.readyState != WebSocket.open) {
      if (type == 'request') {
        source.add(
          jsonEncode({
            'type': 'response',
            'request': request,
            'error': 'Device is offline',
          }),
        );
      }
      return;
    }
    target.add(
      jsonEncode({
        'type': type,
        'from': sender,
        'request': request,
        if (frame['body'] != null) 'body': frame['body'],
        if (frame['error'] != null) 'error': frame['error'],
      }),
    );
  } catch (_) {
    source.close(WebSocketStatus.invalidFramePayloadData, 'Invalid frame');
  }
}

void _remove(String token, String device, WebSocket socket) {
  final members = groups[token];
  if (members?[device] == socket) {
    members!.remove(device);
    _broadcastPresence(token, device, false);
  }
  if (members?.isEmpty == true) groups.remove(token);
}

void _broadcastPresence(
  String token,
  String device,
  bool online, {
  String? except,
}) {
  final message = jsonEncode({
    'type': 'presence',
    'device': device,
    'online': online,
  });
  for (final member in (groups[token] ?? const <String, WebSocket>{}).entries) {
    if (member.key != except && member.value.readyState == WebSocket.open) {
      member.value.add(message);
    }
  }
}

int _connectionCount() =>
    groups.values.fold(0, (total, members) => total + members.length);
