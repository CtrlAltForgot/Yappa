import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:async';

import 'package:flutter/material.dart';

import 'network_asset_scope.dart';

class AvatarImage extends StatefulWidget {
  final String? source;
  final String fallbackInitial;
  final double size;
  final bool animate;
  final BoxFit fit;

  const AvatarImage({
    super.key,
    required this.source,
    required this.fallbackInitial,
    required this.size,
    this.animate = true,
    this.fit = BoxFit.cover,
  });

  @override
  State<AvatarImage> createState() => _AvatarImageState();
}

class _AvatarImageState extends State<AvatarImage> {
  static final LinkedHashMap<String, _GifCacheEntry> _gifCache =
      LinkedHashMap<String, _GifCacheEntry>();
  static int _gifCacheBytes = 0;

  static const int _maxGifCacheEntries = 24;
  static const int _maxGifCacheBytes = 24 * 1024 * 1024;
  static const int _maxAnimatedGifBytes = 2 * 1024 * 1024;

  Future<_GifCacheEntry?>? _gifFuture;
  String? _gifFutureKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _startWarmup();
  }

  @override
  void didUpdateWidget(covariant AvatarImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.source?.trim() ?? '') != (widget.source?.trim() ?? '') ||
        oldWidget.size != widget.size ||
        oldWidget.animate != widget.animate ||
        oldWidget.fit != widget.fit) {
      _startWarmup();
    }
  }

  void _startWarmup() {
    final resolved = widget.source?.trim() ?? '';
    if (resolved.isEmpty) {
      _gifFuture = null;
      _gifFutureKey = null;
      return;
    }

    final gifExtent = _gifExtentPx();

    final dataUri = _tryParseDataUri(resolved);
    if (dataUri != null && _looksLikeGifDataUri(dataUri.mimeType)) {
      final cacheKey = '$resolved@$gifExtent';
      _gifFutureKey = cacheKey;
      _gifFuture = _loadGifEntry(
        cacheKey,
        () async => dataUri.bytes,
        gifExtent,
      );
      return;
    }

    if (_looksLikeGifUrl(resolved)) {
      final cacheKey = '$resolved@$gifExtent';
      _gifFutureKey = cacheKey;
      _gifFuture = _loadGifEntry(
        cacheKey,
        () => _downloadBytes(context, resolved),
        gifExtent,
      );
      return;
    }

    _gifFuture = null;
    _gifFutureKey = null;
  }

  Future<_GifCacheEntry?> _loadGifEntry(
    String cacheKey,
    Future<Uint8List> Function() bytesLoader,
    int gifExtent,
  ) async {
    final cached = _takeFromCache(cacheKey);
    if (cached != null) {
      return cached;
    }

    try {
      final gifBytes = await bytesLoader();
      final firstFramePng = await _extractFirstFramePng(gifBytes, gifExtent);
      if (firstFramePng == null) {
        return null;
      }

      final entry = _GifCacheEntry(
        animatedBytes: gifBytes.lengthInBytes <= _maxAnimatedGifBytes
            ? gifBytes
            : null,
        firstFramePng: firstFramePng,
      );
      _storeInCache(cacheKey, entry);
      return entry;
    } catch (_) {
      return null;
    }
  }

  _GifCacheEntry? _takeFromCache(String cacheKey) {
    final cached = _gifCache.remove(cacheKey);
    if (cached != null) {
      _gifCache[cacheKey] = cached;
    }
    return cached;
  }

  void _storeInCache(String cacheKey, _GifCacheEntry entry) {
    final previous = _gifCache.remove(cacheKey);
    if (previous != null) {
      _gifCacheBytes -= previous.byteSize;
    }

    _gifCache[cacheKey] = entry;
    _gifCacheBytes += entry.byteSize;

    while (_gifCache.length > _maxGifCacheEntries ||
        _gifCacheBytes > _maxGifCacheBytes) {
      final oldestKey = _gifCache.keys.first;
      final removed = _gifCache.remove(oldestKey);
      if (removed != null) {
        _gifCacheBytes -= removed.byteSize;
      }
    }
  }

  int _normalExtentPx(BuildContext context) {
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final logicalSize = widget.size.clamp(1.0, 512.0).toDouble();
    return (logicalSize * dpr).round().clamp(1, 1024);
  }

  int _gifExtentPx() {
    // Decode GIF avatars closer to the actual visible box size.
    // This keeps tiny avatars from looking harsh / over-detailed on desktop.
    return widget.size.round().clamp(16, 512);
  }

  @override
  Widget build(BuildContext context) {
    final resolved = widget.source?.trim() ?? '';
    if (resolved.isEmpty) {
      return _fallback();
    }

    final normalExtent = _normalExtentPx(context);
    final gifExtent = _gifExtentPx();
    final dataUri = _tryParseDataUri(resolved);

    if (dataUri != null) {
      if (_looksLikeGifDataUri(dataUri.mimeType)) {
        final cacheKey = '$resolved@$gifExtent';
        return _buildGifFromFuture(
          cacheKey,
          () async => dataUri.bytes,
          gifExtent,
        );
      }

      return RepaintBoundary(
        child: Image.memory(
          dataUri.bytes,
          fit: widget.fit,
          width: widget.size,
          height: widget.size,
          cacheWidth: normalExtent,
          cacheHeight: normalExtent,
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => _fallback(),
        ),
      );
    }

    if (_looksLikeGifUrl(resolved)) {
      final cacheKey = '$resolved@$gifExtent';
      return _buildGifFromFuture(
        cacheKey,
        () => _downloadBytes(context, resolved),
        gifExtent,
      );
    }

    return RepaintBoundary(
      child: RoutedNetworkImage(
        resolved,
        fit: widget.fit,
        width: widget.size,
        height: widget.size,
        cacheWidth: normalExtent,
        cacheHeight: normalExtent,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _fallback(),
      ),
    );
  }

  Widget _buildGifFromFuture(
    String cacheKey,
    Future<Uint8List> Function() bytesLoader,
    int gifExtent,
  ) {
    final future = (_gifFutureKey == cacheKey && _gifFuture != null)
        ? _gifFuture!
        : _loadGifEntry(cacheKey, bytesLoader, gifExtent);

    return FutureBuilder<_GifCacheEntry?>(
      future: future,
      builder: (context, snapshot) {
        final entry = snapshot.data;
        if (entry == null) {
          if (!snapshot.hasData &&
              snapshot.connectionState == ConnectionState.waiting) {
            final cached = _takeFromCache(cacheKey);
            if (cached != null) {
              return _buildGifLayer(cached, gifExtent);
            }
          }
          return _fallback();
        }
        return _buildGifLayer(entry, gifExtent);
      },
    );
  }

  Widget _buildGifLayer(_GifCacheEntry entry, int gifExtent) {
    final stillImage = RepaintBoundary(
      child: Image.memory(
        entry.firstFramePng,
        fit: widget.fit,
        width: widget.size,
        height: widget.size,
        cacheWidth: gifExtent,
        cacheHeight: gifExtent,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _fallback(),
      ),
    );

    if (!widget.animate || entry.animatedBytes == null) {
      return stillImage;
    }

    return _AnimatedGifLayer(
      animatedBytes: entry.animatedBytes!,
      stillImage: stillImage,
      size: widget.size,
      fit: widget.fit,
      gifExtent: gifExtent,
      fallback: _fallback,
    );
  }

  Widget _fallback() => Text(
    widget.fallbackInitial,
    style: TextStyle(fontSize: widget.size * 0.4, fontWeight: FontWeight.w900),
  );
}

class _AnimatedGifLayer extends StatefulWidget {
  final Uint8List animatedBytes;
  final Widget stillImage;
  final double size;
  final BoxFit fit;
  final int gifExtent;
  final Widget Function() fallback;

  const _AnimatedGifLayer({
    required this.animatedBytes,
    required this.stillImage,
    required this.size,
    required this.fit,
    required this.gifExtent,
    required this.fallback,
  });

  @override
  State<_AnimatedGifLayer> createState() => _AnimatedGifLayerState();
}

class _AnimatedGifLayerState extends State<_AnimatedGifLayer> {
  bool _firstAnimatedFrameReady = false;
  ui.Codec? _codec;
  ui.Image? _frameImage;
  Timer? _frameTimer;
  int _decodeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _startDecoder();
  }

  @override
  void didUpdateWidget(covariant _AnimatedGifLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.animatedBytes, widget.animatedBytes)) {
      _startDecoder();
    }
  }

  Future<void> _startDecoder() async {
    final generation = ++_decodeGeneration;
    _frameTimer?.cancel();
    _codec?.dispose();
    _codec = null;
    _frameImage?.dispose();
    _frameImage = null;
    _firstAnimatedFrameReady = false;
    try {
      final codec = await ui.instantiateImageCodec(
        widget.animatedBytes,
        targetWidth: widget.gifExtent,
        targetHeight: widget.gifExtent,
      );
      if (!mounted || generation != _decodeGeneration) {
        codec.dispose();
        return;
      }
      _codec = codec;
      await _decodeNextFrame(generation);
    } catch (_) {
      if (mounted && generation == _decodeGeneration) {
        setState(() => _firstAnimatedFrameReady = false);
      }
    }
  }

  Future<void> _decodeNextFrame(int generation) async {
    final codec = _codec;
    if (!mounted || generation != _decodeGeneration || codec == null) return;
    try {
      final frame = await codec.getNextFrame();
      if (!mounted || generation != _decodeGeneration) {
        frame.image.dispose();
        return;
      }
      final previous = _frameImage;
      setState(() {
        _frameImage = frame.image;
        _firstAnimatedFrameReady = true;
      });
      previous?.dispose();
      _frameTimer = Timer(
        normalizedGifFrameDuration(frame.duration),
        () => _decodeNextFrame(generation),
      );
    } catch (_) {
      if (mounted && generation == _decodeGeneration) {
        setState(() => _firstAnimatedFrameReady = false);
      }
    }
  }

  @override
  void dispose() {
    _decodeGeneration += 1;
    _frameTimer?.cancel();
    _codec?.dispose();
    _frameImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.stillImage,
        AnimatedOpacity(
          opacity: _firstAnimatedFrameReady ? 1 : 0,
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
          child: RepaintBoundary(
            child: _frameImage == null
                ? widget.fallback()
                : RawImage(
                    image: _frameImage,
                    fit: widget.fit,
                    width: widget.size,
                    height: widget.size,
                    filterQuality: FilterQuality.medium,
                  ),
          ),
        ),
      ],
    );
  }
}

@visibleForTesting
Duration normalizedGifFrameDuration(Duration encoded) {
  // GIF permits an omitted/zero delay. Browsers clamp that case instead of
  // spinning through frames as fast as the decoder can run; match that
  // behavior so uploaded avatars have consistent timing on desktop.
  if (encoded < const Duration(milliseconds: 20)) {
    return const Duration(milliseconds: 100);
  }
  return encoded;
}

class _GifCacheEntry {
  final Uint8List? animatedBytes;
  final Uint8List firstFramePng;

  const _GifCacheEntry({
    required this.animatedBytes,
    required this.firstFramePng,
  });

  int get byteSize =>
      (animatedBytes?.lengthInBytes ?? 0) + firstFramePng.lengthInBytes;
}

class _ParsedDataUri {
  final String mimeType;
  final Uint8List bytes;

  const _ParsedDataUri({required this.mimeType, required this.bytes});
}

_ParsedDataUri? _tryParseDataUri(String source) {
  if (!source.startsWith('data:image/')) {
    return null;
  }

  try {
    final comma = source.indexOf(',');
    if (comma <= 0) {
      return null;
    }

    final header = source.substring(5, comma);
    final mimeType = header.split(';').first.trim().toLowerCase();
    final bytes = base64Decode(source.substring(comma + 1));

    return _ParsedDataUri(mimeType: mimeType, bytes: bytes);
  } catch (_) {
    return null;
  }
}

bool _looksLikeGifDataUri(String mimeType) => mimeType == 'image/gif';

bool _looksLikeGifUrl(String source) {
  try {
    final uri = Uri.parse(source);
    return uri.path.toLowerCase().endsWith('.gif');
  } catch (_) {
    return source.toLowerCase().contains('.gif');
  }
}

Future<Uint8List> _downloadBytes(BuildContext context, String url) =>
    NetworkAssetScope.of(context)(url);

Future<Uint8List?> _extractFirstFramePng(Uint8List bytes, int gifExtent) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: gifExtent,
    targetHeight: gifExtent,
  );

  try {
    final frame = await codec.getNextFrame();
    try {
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return byteData?.buffer.asUint8List();
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
