import 'dart:typed_data';

import 'package:flutter/material.dart';

typedef NetworkAssetLoader = Future<Uint8List> Function(String url);

class NetworkAssetScope extends InheritedWidget {
  final NetworkAssetLoader loader;

  const NetworkAssetScope({
    super.key,
    required this.loader,
    required super.child,
  });

  static NetworkAssetLoader of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<NetworkAssetScope>();
    if (scope == null) {
      throw StateError('NetworkAssetScope is missing.');
    }
    return scope.loader;
  }

  @override
  bool updateShouldNotify(NetworkAssetScope oldWidget) =>
      loader != oldWidget.loader;
}

class RoutedNetworkImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageLoadingBuilder? loadingBuilder;

  const RoutedNetworkImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = false,
    this.errorBuilder,
    this.loadingBuilder,
  });

  @override
  State<RoutedNetworkImage> createState() => _RoutedNetworkImageState();
}

class _RoutedNetworkImageState extends State<RoutedNetworkImage> {
  Future<Uint8List>? _future;
  NetworkAssetLoader? _loader;
  String? _url;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final loader = NetworkAssetScope.of(context);
    if (_loader != loader || _url != widget.url) {
      _loader = loader;
      _url = widget.url;
      _future = loader(widget.url);
    }
  }

  @override
  void didUpdateWidget(covariant RoutedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && _loader != null) {
      _url = widget.url;
      _future = _loader!(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Image.memory(
            snapshot.data!,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth,
            cacheHeight: widget.cacheHeight,
            filterQuality: widget.filterQuality,
            gaplessPlayback: widget.gaplessPlayback,
            errorBuilder: widget.errorBuilder,
          );
        }
        if (snapshot.hasError) {
          return widget.errorBuilder?.call(
                context,
                snapshot.error!,
                snapshot.stackTrace,
              ) ??
              const SizedBox.shrink();
        }
        if (widget.loadingBuilder != null) {
          return widget.loadingBuilder!(context, const SizedBox.shrink(), null);
        }
        return SizedBox(width: widget.width, height: widget.height);
      },
    );
  }
}
