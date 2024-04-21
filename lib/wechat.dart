// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mpflutter_core/mpjs/mpjs.dart' as mpjs;
import 'package:mpflutter_wechat_api/mpflutter_wechat_api.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web/helpers.dart';

import 'src/channel.dart';
import 'src/exception.dart';

class WechatWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  /// The underlying `dart:html` [WebSocket].
  final SocketTask innerWebSocket;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => _closeCode;
  int? _closeCode;

  @override
  String? get closeReason => _closeReason;
  String? _closeReason;

  /// The number of bytes of data that have been queued but not yet transmitted
  /// to the network.
  int? get bufferedAmount => null;

  /// The close code set by the local user.
  ///
  /// To ensure proper ordering, this is stored until we get a done event on
  /// [_controller.local.stream].
  int? _localCloseCode;

  /// The close reason set by the local user.
  ///
  /// To ensure proper ordering, this is stored until we get a done event on
  /// [_controller.local.stream].
  String? _localCloseReason;

  /// Completer for [ready].
  late Completer<void> _readyCompleter;

  @override
  Future<void> get ready => _readyCompleter.future;

  @override
  Stream get stream => _controller.foreign.stream;

  final _controller =
      StreamChannelController<Object?>(sync: true, allowForeignErrors: false);

  @override
  late final WebSocketSink sink = _WechatWebSocketSink(this);

  WechatWebSocketChannel.connect(
    Object url, {
    Iterable<String>? protocols,
  }) : this(
          wx.connectSocket(ConnectSocketOption()
            ..url = url.toString()
            ..protocols = protocols?.toList()),
        );

  /// Creates a channel wrapping [innerWebSocket].
  WechatWebSocketChannel(this.innerWebSocket) {
    _readyCompleter = Completer();

    innerWebSocket.onOpen((p0) {
      _readyCompleter.complete();
      _listen();
    });

    innerWebSocket.onError((p0) {
      // Unfortunately, the underlying WebSocket API doesn't expose any
      // specific information about the error itself.
      final error = WebSocketChannelException('WebSocket connection failed.');
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.completeError(error);
      }
      _controller.local.sink.addError(error);
      _controller.local.sink.close();
    });

    innerWebSocket.onMessage((p0) {
      _innerListen(p0.data);
    });

    innerWebSocket.onClose((p0) {
      _closeCode = p0.code.toInt();
      _closeReason = p0.reason;
      _controller.local.sink.close();
    });
  }

  void _innerListen(dynamic data) {
    if (data is String) {
      _controller.local.sink.add(data);
    } else if (data is mpjs.JSObject) {
      _controller.local.sink.add(
        mpjs.context.convertArrayBufferToUint8List(data),
      );
    }
  }

  void _listen() {
    _controller.local.stream.listen(
        (obj) => innerWebSocket.send(SocketTaskSendOption()
          ..data = (() {
            if (obj is Uint8List) {
              return mpjs.context.newArrayBufferFromUint8List(obj);
            }
            return obj;
          })()), onDone: () {
      if ((_localCloseCode, _localCloseReason)
          case (final closeCode?, final closeReason?)) {
        innerWebSocket.close(SocketTaskCloseOption()
          ..code = closeCode
          ..reason = closeReason);
      } else if (_localCloseCode case final closeCode?) {
        innerWebSocket.close(SocketTaskCloseOption()..code = closeCode);
      } else {
        innerWebSocket.close(SocketTaskCloseOption());
      }
    });
  }
}

class _WechatWebSocketSink extends DelegatingStreamSink
    implements WebSocketSink {
  final WechatWebSocketChannel _channel;

  _WechatWebSocketSink(WechatWebSocketChannel channel)
      : _channel = channel,
        super(channel._controller.foreign.sink);

  @override
  Future close([int? closeCode, String? closeReason]) {
    _channel._localCloseCode = closeCode;
    _channel._localCloseReason = closeReason;
    return super.close();
  }
}
