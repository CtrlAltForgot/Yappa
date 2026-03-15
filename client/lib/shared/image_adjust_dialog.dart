import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class AdjustedImageResult {
  final Uint8List bytes;
  final String extension;
  final String mimeType;

  const AdjustedImageResult({
    required this.bytes,
    required this.extension,
    required this.mimeType,
  });
}


class _CropSelection {
  final int cropX;
  final int cropY;
  final int cropWidth;
  final int cropHeight;

  const _CropSelection({
    required this.cropX,
    required this.cropY,
    required this.cropWidth,
    required this.cropHeight,
  });
}

class _OutputSize {
  final int targetWidth;
  final int targetHeight;

  const _OutputSize({
    required this.targetWidth,
    required this.targetHeight,
  });
}

Future<AdjustedImageResult?> showImageAdjustDialog({
  required BuildContext context,
  required Uint8List sourceBytes,
  required double aspectRatio,
  required String originalExtension,
  int maxOutputDimension = 512,
  String? title,
}) {
  return showDialog<AdjustedImageResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _ImageAdjustDialog(
      sourceBytes: sourceBytes,
      aspectRatio: aspectRatio,
      originalExtension: originalExtension,
      maxOutputDimension: maxOutputDimension,
      title: title ?? 'Adjust image',
    ),
  );
}

class _ImageAdjustDialog extends StatefulWidget {
  final Uint8List sourceBytes;
  final double aspectRatio;
  final String originalExtension;
  final int maxOutputDimension;
  final String title;

  const _ImageAdjustDialog({
    required this.sourceBytes,
    required this.aspectRatio,
    required this.originalExtension,
    required this.maxOutputDimension,
    required this.title,
  });

  @override
  State<_ImageAdjustDialog> createState() => _ImageAdjustDialogState();
}

class _ImageAdjustDialogState extends State<_ImageAdjustDialog> {
  late final String _normalizedExtension;
  late final bool _isGif;
  late final img.Image? _decoded;
  late final Uint8List? _previewBytes;

  double _zoom = 1.0;
  Offset _offset = Offset.zero;
  int _quarterTurns = 0;

  double _gestureStartZoom = 1.0;
  Offset _gestureStartOffset = Offset.zero;
  Offset _gestureStartFocalPoint = Offset.zero;

  Rect _lastCropRect = Rect.zero;

  String? _error;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _normalizedExtension = widget.originalExtension.trim().toLowerCase();
    _isGif = _normalizedExtension == 'gif';
    try {
      _decoded = _decodeSource(widget.sourceBytes, _isGif);
      if (_decoded == null) {
        _previewBytes = null;
        _error = 'That image could not be decoded.';
      } else {
        final previewFrame = _decodePreviewFrame(widget.sourceBytes, _isGif) ?? _decoded;
        _previewBytes = Uint8List.fromList(img.encodePng(previewFrame));
      }
    } catch (_) {
      _previewBytes = null;
      _error = 'That image could not be decoded.';
    }
  }

  img.Image? _decodeSource(Uint8List bytes, bool isGif) {
    if (isGif) {
      final decoded = img.GifDecoder().decode(bytes);
      return decoded ?? img.decodeImage(bytes);
    }
    return img.decodeImage(bytes);
  }

  img.Image? _decodePreviewFrame(Uint8List bytes, bool isGif) {
    if (isGif) {
      return img.decodeImage(bytes, frame: 0);
    }
    return img.decodeImage(bytes);
  }

  Size get _sourceSize {
    final decoded = _decoded;
    if (decoded == null) {
      return const Size(1, 1);
    }
    if (_quarterTurns.isOdd) {
      return Size(decoded.height.toDouble(), decoded.width.toDouble());
    }
    return Size(decoded.width.toDouble(), decoded.height.toDouble());
  }

  void _resetAdjustments() {
    setState(() {
      _zoom = 1.0;
      _offset = Offset.zero;
      _quarterTurns = 0;
    });
  }

  double _baseScaleFor(Rect cropRect) {
    final sourceSize = _sourceSize;
    return math.max(
      cropRect.width / sourceSize.width,
      cropRect.height / sourceSize.height,
    );
  }

  Offset _clampOffsetFor({
    required Rect cropRect,
    required Size sourceSize,
    required double displayedScale,
    required Offset proposed,
  }) {
    final imageWidth = sourceSize.width * displayedScale;
    final imageHeight = sourceSize.height * displayedScale;
    final maxDx = math.max(0.0, (imageWidth - cropRect.width) / 2);
    final maxDy = math.max(0.0, (imageHeight - cropRect.height) / 2);
    return Offset(
      proposed.dx.clamp(-maxDx, maxDx).toDouble(),
      proposed.dy.clamp(-maxDy, maxDy).toDouble(),
    );
  }

  void _handlePointerScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _lastCropRect == Rect.zero || _decoded == null) {
      return;
    }
    final nextZoom = (_zoom * (event.scrollDelta.dy > 0 ? 0.93 : 1.07))
        .clamp(1.0, 8.0)
        .toDouble();
    final scale = _baseScaleFor(_lastCropRect) * nextZoom;
    final nextOffset = _clampOffsetFor(
      cropRect: _lastCropRect,
      sourceSize: _sourceSize,
      displayedScale: scale,
      proposed: _offset,
    );
    setState(() {
      _zoom = nextZoom;
      _offset = nextOffset;
    });
  }

  _CropSelection _resolveCropPixels(
    img.Image reference,
  ) {
    final sourceSize = Size(reference.width.toDouble(), reference.height.toDouble());
    final baseScale = math.max(
      _lastCropRect.width / sourceSize.width,
      _lastCropRect.height / sourceSize.height,
    );
    final displayedScale = baseScale * _zoom;
    final effectiveOffset = _clampOffsetFor(
      cropRect: _lastCropRect,
      sourceSize: sourceSize,
      displayedScale: displayedScale,
      proposed: _offset,
    );

    final imageRect = Rect.fromCenter(
      center: _lastCropRect.center + effectiveOffset,
      width: sourceSize.width * displayedScale,
      height: sourceSize.height * displayedScale,
    );

    final srcLeft = ((_lastCropRect.left - imageRect.left) / displayedScale)
        .clamp(0.0, sourceSize.width)
        .toDouble();
    final srcTop = ((_lastCropRect.top - imageRect.top) / displayedScale)
        .clamp(0.0, sourceSize.height)
        .toDouble();
    final srcRight = ((_lastCropRect.right - imageRect.left) / displayedScale)
        .clamp(0.0, sourceSize.width)
        .toDouble();
    final srcBottom = ((_lastCropRect.bottom - imageRect.top) / displayedScale)
        .clamp(0.0, sourceSize.height)
        .toDouble();

    var cropX = srcLeft.floor();
    var cropY = srcTop.floor();
    var cropWidth = math.max(1, (srcRight - srcLeft).round());
    var cropHeight = math.max(1, (srcBottom - srcTop).round());

    if (cropX + cropWidth > reference.width) {
      cropWidth = reference.width - cropX;
    }
    if (cropY + cropHeight > reference.height) {
      cropHeight = reference.height - cropY;
    }

    cropWidth = math.max(1, cropWidth);
    cropHeight = math.max(1, cropHeight);

    return _CropSelection(
      cropX: cropX,
      cropY: cropY,
      cropWidth: cropWidth,
      cropHeight: cropHeight,
    );
  }

  _OutputSize _resolveOutputSize() {
    final targetWidth = widget.aspectRatio >= 1
        ? widget.maxOutputDimension
        : (widget.maxOutputDimension * widget.aspectRatio)
            .round()
            .clamp(1, widget.maxOutputDimension);
    final targetHeight = widget.aspectRatio >= 1
        ? (widget.maxOutputDimension / widget.aspectRatio)
            .round()
            .clamp(1, widget.maxOutputDimension)
        : widget.maxOutputDimension;
    return _OutputSize(targetWidth: targetWidth, targetHeight: targetHeight);
  }

  img.Image _transformFrame(
    img.Image frame, {
    required _CropSelection crop,
    required _OutputSize outputSize,
  }) {
    var working = frame.clone(noAnimation: true);
    if (_quarterTurns != 0) {
      working = img.copyRotate(working, angle: _quarterTurns * 90);
    }

    final cropped = img.copyCrop(
      working,
      x: crop.cropX,
      y: crop.cropY,
      width: crop.cropWidth,
      height: crop.cropHeight,
    );

    return img.copyResize(
      cropped,
      width: outputSize.targetWidth,
      height: outputSize.targetHeight,
      interpolation: img.Interpolation.average,
    );
  }

  Future<void> _finish() async {
    final decoded = _decoded;
    if (decoded == null || _lastCropRect == Rect.zero) {
      return;
    }

    setState(() {
      _exporting = true;
    });

    try {
      final referenceFrame = _quarterTurns == 0
          ? decoded.clone(noAnimation: true)
          : img.copyRotate(decoded.clone(noAnimation: true), angle: _quarterTurns * 90);
      final crop = _resolveCropPixels(referenceFrame);
      final outputSize = _resolveOutputSize();

      late final Uint8List outputBytes;
      late final String extension;
      late final String mimeType;

      if (_isGif && decoded.numFrames > 1) {
        final encoder = img.GifEncoder();
        encoder.repeat = decoded.loopCount;
        for (final frame in decoded.frames) {
          final transformed = _transformFrame(
            frame,
            crop: crop,
            outputSize: outputSize,
          );
          final frameDuration = (frame.frameDuration / 10).round();
          encoder.addFrame(
            transformed,
            duration: frameDuration <= 0 ? null : frameDuration,
          );
        }
        outputBytes = encoder.finish() ?? Uint8List(0);
        extension = 'gif';
        mimeType = 'image/gif';
      } else {
        final transformed = _transformFrame(
          decoded,
          crop: crop,
          outputSize: outputSize,
        );
        if (_isGif) {
          outputBytes = img.GifEncoder().encode(transformed);
          extension = 'gif';
          mimeType = 'image/gif';
        } else {
          outputBytes = Uint8List.fromList(img.encodePng(transformed));
          extension = 'png';
          mimeType = 'image/png';
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop(
        AdjustedImageResult(
          bytes: outputBytes,
          extension: extension,
          mimeType: mimeType,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not finish that crop.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewBytes = _previewBytes;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 980,
        height: 700,
        decoration: BoxDecoration(
          color: const Color(0xFF12141B),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF2A2F3A)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x77000000),
              blurRadius: 30,
              offset: Offset(0, 18),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: previewBytes == null
            ? _ErrorPane(
                title: widget.title,
                message: _error ?? 'That image could not be decoded.',
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isGif
                          ? 'GIF detected. You are framing the first frame, and the same crop will be applied to every frame.'
                          : 'Drag to reposition, zoom to frame it, and save when the preview looks right.',
                      style: const TextStyle(color: Color(0xFF9FA8BA)),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF0C0E13),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: const Color(0xFF232834)),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final viewportSize = Size(
                                    constraints.maxWidth,
                                    constraints.maxHeight,
                                  );
                                  final cropRect = _cropRectFor(viewportSize, widget.aspectRatio);
                                  final sourceSize = _sourceSize;
                                  final baseScale = _baseScaleFor(cropRect);
                                  final displayedScale = baseScale * _zoom;
                                  final effectiveOffset = _clampOffsetFor(
                                    cropRect: cropRect,
                                    sourceSize: sourceSize,
                                    displayedScale: displayedScale,
                                    proposed: _offset,
                                  );
                                  final imageRect = Rect.fromCenter(
                                    center: cropRect.center + effectiveOffset,
                                    width: sourceSize.width * displayedScale,
                                    height: sourceSize.height * displayedScale,
                                  );

                                  _lastCropRect = cropRect;

                                  return Listener(
                                    onPointerSignal: _handlePointerScroll,
                                    child: GestureDetector(
                                      onScaleStart: (details) {
                                        _gestureStartZoom = _zoom;
                                        _gestureStartOffset = _offset;
                                        _gestureStartFocalPoint = details.focalPoint;
                                      },
                                      onScaleUpdate: (details) {
                                        final nextZoom = (_gestureStartZoom * details.scale)
                                            .clamp(1.0, 8.0)
                                            .toDouble();
                                        final nextScale = baseScale * nextZoom;
                                        final dragDelta = details.focalPoint - _gestureStartFocalPoint;
                                        final nextOffset = _clampOffsetFor(
                                          cropRect: cropRect,
                                          sourceSize: sourceSize,
                                          displayedScale: nextScale,
                                          proposed: _gestureStartOffset + dragDelta,
                                        );
                                        setState(() {
                                          _zoom = nextZoom;
                                          _offset = nextOffset;
                                        });
                                      },
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          Positioned.fromRect(
                                            rect: imageRect,
                                            child: IgnorePointer(
                                              child: RotatedBox(
                                                quarterTurns: _quarterTurns,
                                                child: Image.memory(
                                                  previewBytes,
                                                  fit: BoxFit.fill,
                                                  filterQuality: FilterQuality.high,
                                                  gaplessPlayback: true,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned.fill(
                                            child: CustomPaint(
                                              painter: _CropOverlayPainter(cropRect: cropRect),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 18),
                          SizedBox(
                            width: 250,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Final crop',
                                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                                ),
                                const SizedBox(height: 10),
                                AspectRatio(
                                  aspectRatio: widget.aspectRatio,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0C0E13),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: const Color(0xFF2A2F3A)),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: _lastCropRect == Rect.zero
                                        ? const SizedBox.shrink()
                                        : _PreviewPane(
                                            previewBytes: previewBytes,
                                            cropRect: _lastCropRect,
                                            imageRect: Rect.fromCenter(
                                              center: _lastCropRect.center + _clampOffsetFor(
                                                cropRect: _lastCropRect,
                                                sourceSize: _sourceSize,
                                                displayedScale: _baseScaleFor(_lastCropRect) * _zoom,
                                                proposed: _offset,
                                              ),
                                              width: _sourceSize.width * _baseScaleFor(_lastCropRect) * _zoom,
                                              height: _sourceSize.height * _baseScaleFor(_lastCropRect) * _zoom,
                                            ),
                                            quarterTurns: _quarterTurns,
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  'Zoom',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Slider(
                                  value: _zoom,
                                  min: 1.0,
                                  max: 8.0,
                                  divisions: 70,
                                  onChanged: (value) {
                                    final nextScale = _baseScaleFor(_lastCropRect) * value;
                                    final nextOffset = _clampOffsetFor(
                                      cropRect: _lastCropRect,
                                      sourceSize: _sourceSize,
                                      displayedScale: nextScale,
                                      proposed: _offset,
                                    );
                                    setState(() {
                                      _zoom = value;
                                      _offset = nextOffset;
                                    });
                                  },
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () {
                                        setState(() {
                                          _quarterTurns = (_quarterTurns - 1) % 4;
                                          _offset = Offset.zero;
                                          _zoom = 1.0;
                                        });
                                      },
                                      icon: const Icon(Icons.rotate_left_rounded, size: 18),
                                      label: const Text('Rotate left'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () {
                                        setState(() {
                                          _quarterTurns = (_quarterTurns + 1) % 4;
                                          _offset = Offset.zero;
                                          _zoom = 1.0;
                                        });
                                      },
                                      icon: const Icon(Icons.rotate_right_rounded, size: 18),
                                      label: const Text('Rotate right'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: _resetAdjustments,
                                      icon: const Icon(Icons.refresh_rounded, size: 18),
                                      label: const Text('Reset'),
                                    ),
                                  ],
                                ),
                                if (_error != null) ...[
                                  const SizedBox(height: 14),
                                  Text(
                                    _error!,
                                    style: const TextStyle(
                                      color: Color(0xFFFFB4BF),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                                const Spacer(),
                                Text(
                                  'The darker area is what gets cut off.',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.55),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _exporting ? null : () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton.icon(
                          onPressed: _exporting ? null : _finish,
                          icon: _exporting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check_rounded, size: 18),
                          label: const Text('Use crop'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Rect _cropRectFor(Size viewport, double aspectRatio) {
    final maxWidth = viewport.width * 0.72;
    final maxHeight = viewport.height * 0.72;

    double cropWidth = maxWidth;
    double cropHeight = cropWidth / aspectRatio;
    if (cropHeight > maxHeight) {
      cropHeight = maxHeight;
      cropWidth = cropHeight * aspectRatio;
    }

    final left = (viewport.width - cropWidth) / 2;
    final top = (viewport.height - cropHeight) / 2;
    return Rect.fromLTWH(left, top, cropWidth, cropHeight);
  }
}

class _PreviewPane extends StatelessWidget {
  final Uint8List previewBytes;
  final Rect cropRect;
  final Rect imageRect;
  final int quarterTurns;

  const _PreviewPane({
    required this.previewBytes,
    required this.cropRect,
    required this.imageRect,
    required this.quarterTurns,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaleX = constraints.maxWidth / cropRect.width;
        final scaleY = constraints.maxHeight / cropRect.height;
        final previewRect = Rect.fromLTWH(
          (imageRect.left - cropRect.left) * scaleX,
          (imageRect.top - cropRect.top) * scaleY,
          imageRect.width * scaleX,
          imageRect.height * scaleY,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: previewRect,
              child: IgnorePointer(
                child: RotatedBox(
                  quarterTurns: quarterTurns,
                  child: Image.memory(
                    previewBytes,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.high,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;

  const _CropOverlayPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Paint()..color = const Color(0xAA000000);
    final clearPath = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(cropRect, const Radius.circular(24)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(clearPath, overlay);

    final borderPaint = Paint()
      ..color = const Color(0xFFDCE7FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(cropRect, const Radius.circular(24)),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) {
    return oldDelegate.cropRect != cropRect;
  }
}

class _ErrorPane extends StatelessWidget {
  final String title;
  final String message;

  const _ErrorPane({
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(
              color: Color(0xFFFFB4BF),
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Align(
            alignment: Alignment.bottomRight,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ),
        ],
      ),
    );
  }
}
