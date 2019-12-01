// Copyright 2019 dartssh developers
// Use of this source code is governed by a MIT-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh/client.dart';
import 'package:dartssh/http.dart';
import 'package:dartssh/protocol.dart';
import 'package:dartssh/socket.dart';
import 'package:dartssh/socket_io.dart';
import 'package:dartssh/transport.dart';

/// dart:io [WebSocket] based implementation of [SocketInterface].
class WebSocketImpl extends SocketInterface {
  static const String type = 'io';

  io.WebSocket socket;

  @override
  void close() {
    if (socket != null) {
      socket.close();
      socket == null;
    }
  }

  @override
  void connect(Uri uri, VoidCallback onConnected, StringCallback onError,
      {int timeoutSeconds = 15, bool ignoreBadCert = false}) async {
    if (!ignoreBadCert || !uri.hasScheme || uri.scheme != 'wss') {
      return io.WebSocket.connect('$uri')
          .timeout(Duration(seconds: timeoutSeconds))
          .then((io.WebSocket x) {
        socket = x;
        onConnected();
      }, onError: (error, _) => onError(error));
    }

    io.HttpClient client = io.HttpClient();
    client.badCertificateCallback =
        (io.X509Certificate cert, String host, int port) => true;

    /// Upgrade https to wss using [badCertificateCallback] to allow
    /// self-signed certificates.  This still gains you stream encryption.
    try {
      io.HttpClientRequest request =
          await client.getUrl(Uri.parse('https' + '$uri'.substring(3)));
      request.headers.add('Connection', 'upgrade');
      request.headers.add('Upgrade', 'websocket');
      request.headers.add('sec-websocket-version', '13');
      request.headers.add(
          'sec-websocket-key', base64.encode(randBytes(Random.secure(), 8)));

      io.HttpClientResponse response = await request.close()
        ..timeout(Duration(seconds: timeoutSeconds));

      socket = io.WebSocket.fromUpgradedSocket(await response.detachSocket(),
          serverSide: false);
      onConnected();
    } catch (error) {
      onError(error);
    }
  }

  @override
  void handleError(StringCallback errorHandler) {
    socket.handleError((error, _) {
      errorHandler(error);
    });
  }

  @override
  void handleDone(StringCallback doneHandler) {
    socket.done.then((_) {
      doneHandler(
          'WebSocketImpl.handleDone: ${socket.closeCode} ${socket.closeReason}');
      return null;
    });
  }

  @override
  void listen(Uint8ListCallback messageHandler) => socket.listen((m) {
        //print("WebSocketImpl.read: $m");
        messageHandler(utf8.encode(m));
      });

  @override
  void send(String text) => socket.addUtf8Text(utf8.encode(text));

  @override
  void sendRaw(Uint8List raw) => socket.add(raw);
}

/// The initial [SSHTunneledSocketImpl] (which implements same [SocketInteface]
/// as [SSHTunneledWebSocketImpl]), is bridged via [SSHTunneledSocket] adaptor
/// to initialize [io.WebSocket.fromUpgradedSocket()].
class SSHTunneledWebSocketImpl extends WebSocketImpl {
  SSHTunneledSocketImpl tunneledSocket;
  SSHTunneledWebSocketImpl(this.tunneledSocket);

  @override
  void connect(Uri uri, VoidCallback onConnected, StringCallback onError,
      {int timeoutSeconds = 15, bool ignoreBadCert = false}) async {
    HttpResponse response = await tunneledHttpRequest(
      Uri.parse('http' + '$uri'.substring(2)),
      'GET',
      tunneledSocket,
      requestHeaders: <String, String>{
        'Connection': 'upgrade',
        'Upgrade': 'websocket',
        'sec-websocket-version': '13',
        'sec-websocket-key': base64.encode(randBytes(Random.secure(), 8))
      },
      debugPrint: tunneledSocket.client.debugPrint,
    );
    if (response.status == 101) {
      socket = io.WebSocket.fromUpgradedSocket(
          SSHTunneledSocket(tunneledSocket),
          serverSide: false);
      onConnected();
    } else {
      onError('status ${response.status} ${response.reason}');
    }
    tunneledSocket = null;
  }
}