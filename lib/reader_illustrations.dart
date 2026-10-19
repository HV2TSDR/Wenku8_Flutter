import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_ui.dart';
import 'app_interactions.dart';
import 'local_platform.dart';
import 'cover_arrival.dart';
import 'legacy_transport.dart';
import 'local_book_media.dart';
import 'local_image_layout.dart';

typedef IllustrationRequest = Future<Uint8List> Function(String url);

/// Decoded images are bounded by Flutter's image cache; encoded images by bytes,
/// not by chapter count. Completed futures are not retained after eviction.
class ReaderIllustrationCache {
  ReaderIllustrationCache({
    IllustrationRequest? request,
    this.maxBytes = 16 * 1024 * 1024,
  }) : _request = request ?? LegacyTransport.illustration;
  static final shared = ReaderIllustrationCache();
  final IllustrationRequest _request;
  final int maxBytes;
  final _pending = <String, Future<Uint8List>>{};
  final _cache = <String, Uint8List>{};
  final _dimensions = <String, Size>{};
  // Header inspection is shared by the inline view and gallery. Weak byte keys
  // follow the encoded cache, without retaining another copy of an illustration.
  static final _sizes = Expando<Size>('illustration-size');
  static final _sizeRequests = Expando<Future<Size>>('illustration-size-read');
  int _bytes = 0;
  int _epoch = 0;
  int get encodedBytes => _bytes;
  Uint8List? peek(String url) => _cache[url];
  Size? sizeOf(String url) {
    if (_dimensions[url] case final size?) return size;
    final bytes = peek(url);
    return bytes == null ? null : _sizes[bytes];
  }

  Future<Size> dimensions(String url) async {
    if (sizeOf(url) case final size?) return size;
    return _rememberSize(url, await load(url));
  }

  Future<Size> _rememberSize(String url, Uint8List bytes) async {
    final epoch = _epoch;
    final size = await _size(bytes);
    if (epoch == _epoch) {
      if (_dimensions.length >= 256) _dimensions.remove(_dimensions.keys.first);
      _dimensions[url] = size;
    }
    return size;
  }

  /// Pagination needs header dimensions, not decoded pixels. Repeated note
  /// icons share one request; canceled layouts stop scheduling further reads.
  Future<Map<String, Size>> measureLocalImages(
    Iterable<String> urls, {
    required bool Function() current,
  }) async {
    final local = urls
        .where((u) => u.startsWith('wenku-local:'))
        .toSet()
        .toList();
    final result = <String, Size>{};
    for (var start = 0; start < local.length && current(); start += 4) {
      await Future.wait(
        local.skip(start).take(4).map((url) async {
          try {
            result[url] = await dimensions(url);
          } catch (_) {
            /* A broken image retains its reader retry, not a broken chapter. */
          }
        }),
      );
    }
    return result;
  }

  Future<Size> _size(Uint8List bytes) => _sizeRequests[bytes] ??= () async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final size = Size(
          descriptor.width.toDouble(),
          descriptor.height.toDouble(),
        );
        if (size.isEmpty) throw const FormatException('插图尺寸无效');
        _sizes[bytes] = size;
        return size;
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }();

  void evict(String url) {
    _dimensions.remove(url);
    final bytes = _cache.remove(url);
    if (bytes != null) _bytes -= bytes.length;
  }

  Future<Uint8List> load(String url) {
    final cached = _cache.remove(url);
    if (cached != null) {
      _cache[url] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(url, () async {
      final epoch = _epoch;
      try {
        final bytes = url.startsWith('wenku-local:')
            ? await LocalBookMedia.load(url)
            : await _request(url);
        if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
          throw const FormatException('插图大小无效');
        }
        if (epoch == _epoch && bytes.length <= maxBytes) {
          while (_bytes + bytes.length > maxBytes && _cache.isNotEmpty) {
            _bytes -= _cache.remove(_cache.keys.first)!.length;
          }
          _cache[url] = bytes;
          _bytes += bytes.length;
        }
        return bytes;
      } finally {
        if (epoch == _epoch) _pending.remove(url);
      }
    });
  }

  void clearMemory() {
    _epoch++;
    _cache.clear();
    _pending.clear();
    _dimensions.clear();
    _bytes = 0;
  }
}

/// Scrolling illustrations use their own aspect ratio and the actual text
/// column width. Page illustrations instead use the whole leaf without cropping.
class ReaderIllustrationFrame extends StatelessWidget {
  const ReaderIllustrationFrame({
    super.key,
    required this.child,
    this.imageSize,
    this.fitPage = false,
    this.preserveSize = false,
    this.localLayout = const LocalImageLayout(),
    this.fontSize = 19,
  });

  final Widget child;
  final Size? imageSize;
  final bool fitPage;
  final bool preserveSize;
  final LocalImageLayout localLayout;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    if (preserveSize) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final available = Size(
            constraints.hasBoundedWidth
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width,
            constraints.hasBoundedHeight
                ? constraints.maxHeight
                : double.infinity,
          );
          final target = localLayout.resolve(
            natural: imageSize ?? const Size(32, 32),
            available: available,
            fontSize: fontSize,
          );
          return AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Align(
              alignment: fitPage ? Alignment.center : Alignment.topCenter,
              heightFactor: fitPage ? null : 1,
              child: SizedBox(
                width: target.width,
                height: target.height,
                child: child,
              ),
            ),
          );
        },
      );
    }
    if (fitPage) return SizedBox.expand(child: child);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: width / (imageSize?.aspectRatio ?? .75),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class ReaderIllustration extends StatefulWidget {
  const ReaderIllustration({
    super.key,
    required this.url,
    this.onOpen,
    this.cache,
    this.fullScreen = false,
    this.fitPage = false,
    this.localLayout = const LocalImageLayout(),
    this.fontSize = 19,
    this.sizedFrame = false,
  });
  final String url;
  final VoidCallback? onOpen;
  final ReaderIllustrationCache? cache;
  final bool fullScreen;
  final bool fitPage;
  final LocalImageLayout localLayout;
  final double fontSize;

  /// Pagination has already resolved percentages against the whole leaf.
  final bool sizedFrame;
  @override
  State<ReaderIllustration> createState() => _ReaderIllustrationState();
}

class _ReaderIllustrationState extends State<ReaderIllustration> {
  ReaderIllustrationCache get _cache =>
      widget.cache ?? ReaderIllustrationCache.shared;
  late Future<({Uint8List? bytes, Size? size, Object? error})> _future =
      _load();
  Future<({Uint8List? bytes, Size? size, Object? error})> _load() async {
    try {
      final cache = _cache, url = widget.url;
      final bytes = await cache.load(url);
      final size = await cache._rememberSize(url, bytes);
      return (bytes: bytes, size: size, error: null);
    } catch (error) {
      return (bytes: null, size: null, error: error);
    }
  }

  @override
  void didUpdateWidget(ReaderIllustration old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.cache != widget.cache) _future = _load();
  }

  @override
  Widget build(BuildContext context) {
    final cached = _cache.peek(widget.url), size = _cache.sizeOf(widget.url);
    return RepaintBoundary(
      child: FutureBuilder<({Uint8List? bytes, Size? size, Object? error})>(
        key: ObjectKey(_future),
        future: _future,
        initialData: cached != null && size != null
            ? (bytes: cached, size: size, error: null)
            : null,
        builder: (context, snapshot) {
          final bytes = snapshot.data?.bytes;
          Widget frame(Widget child) => widget.sizedFrame
              ? SizedBox.expand(child: child)
              : ReaderIllustrationFrame(
                  imageSize: snapshot.data?.size,
                  fitPage: widget.fullScreen || widget.fitPage,
                  preserveSize:
                      !widget.fullScreen &&
                      widget.url.startsWith('wenku-local:'),
                  localLayout: widget.localLayout,
                  fontSize: widget.fontSize,
                  child: child,
                );
          Widget localRetry() => Semantics(
            button: true,
            label: '图片加载失败，点按重试',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _cache.evict(widget.url);
                setState(() {
                  _future = _load();
                });
              },
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(CupertinoIcons.arrow_clockwise, size: 24),
                ),
              ),
            ),
          );
          if (snapshot.data?.error != null) {
            if (widget.url.startsWith('wenku-local:')) {
              return frame(localRetry());
            }
            return frame(
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(CupertinoIcons.photo, size: 28),
                    const SizedBox(height: 12),
                    const AppText('插图加载失败'),
                    GlassTextButton(
                      onPressed: () {
                        _cache.evict(widget.url);
                        setState(() {
                          _future = _load();
                        });
                      },
                      child: const AppText('重试插图'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (bytes == null) {
            return frame(
              const LoadingSkeleton(
                layout: SkeletonLayout.cover,
                label: '正在载入插图',
              ),
            );
          }
          return frame(
            LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                onTap: widget.onOpen,
                child: Semantics(
                  label: '章节插图，点击查看大图',
                  image: true,
                  child: Image.memory(
                    bytes,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    fit: BoxFit.contain,
                    cacheWidth:
                        (widget.fullScreen
                                ? 2400
                                : (constraints.maxWidth *
                                          MediaQuery.devicePixelRatioOf(
                                            context,
                                          ))
                                      .round()
                                      .clamp(1, 1600))
                            .clamp(
                              1,
                              snapshot.data!.size!.width.round().clamp(1, 2400),
                            ),
                    frameBuilder: (context, child, frame, sync) => CoverArrival(
                      bytes: bytes,
                      ready: frame != null,
                      placeholder: const LoadingSkeleton(
                        layout: SkeletonLayout.cover,
                        label: '正在解码插图',
                      ),
                      child: child,
                    ),
                    errorBuilder: (context, error, stack) =>
                        widget.url.startsWith('wenku-local:')
                        ? localRetry()
                        : Center(
                            child: GlassTextButton(
                              onPressed: () {
                                _cache.evict(widget.url);
                                setState(() {
                                  _future = _load();
                                });
                              },
                              child: const AppText('重新读取插图'),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ReaderIllustrationGallery extends StatefulWidget {
  const ReaderIllustrationGallery({
    super.key,
    required this.urls,
    required this.initialUrl,
    this.cache,
    this.title = '章节插图',
    this.fileNamePrefix = '文库插图',
  }) : assert(urls.length > 0);
  final List<String> urls;
  final String initialUrl;
  final ReaderIllustrationCache? cache;
  final String title, fileNamePrefix;
  @override
  State<ReaderIllustrationGallery> createState() =>
      _ReaderIllustrationGalleryState();
}

class _ReaderIllustrationGalleryState extends State<ReaderIllustrationGallery> {
  late int _page = widget.urls
      .indexOf(widget.initialUrl)
      .clamp(0, widget.urls.length - 1);
  late final _pages = PageController(initialPage: _page);
  bool _saving = false;
  int? _dragPage;
  void _dragStart(ScaleStartDetails details) {
    _dragCancel();
    _dragPage = _pages.page!.round();
    _pages.jumpTo(_pages.offset);
  }

  void _dragUpdate(ScaleUpdateDetails details) {
    if (_dragPage == null) return;
    final position = _pages.position;
    _pages.jumpTo(
      (position.pixels - details.focalPointDelta.dx).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  void _dragEnd(ScaleEndDetails details) {
    final origin = _dragPage;
    _dragPage = null;
    if (origin == null) return;
    final distance = _pages.page! - origin;
    final velocity = -details.velocity.pixelsPerSecond.dx;
    final step = velocity.abs() > 350
        ? velocity.sign.toInt()
        : distance.abs() > .2
        ? distance.sign.toInt()
        : 0;
    _pages.animateToPage(
      (origin + step).clamp(0, widget.urls.length - 1),
      duration: NovelMotion.contact,
      curve: NovelMotion.ease,
    );
  }

  void _dragCancel() {
    final origin = _dragPage;
    _dragPage = null;
    if (origin != null) _pages.jumpToPage(origin);
  }

  Future<void> _save() async {
    if (_saving) return;
    final page = _page;
    setState(() => _saving = true);
    try {
      final bytes = await (widget.cache ?? ReaderIllustrationCache.shared).load(
        widget.urls[page],
      );
      final saved = await LocalPlatform.saveBookImage(
        bytes,
        '${widget.fileNamePrefix}-${page + 1}',
      );
      if (mounted && saved) showNovelFeedback(context, '图片已保存');
    } catch (_) {
      if (mounted) showNovelFeedback(context, '图片保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _dragPage = null;
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Atmosphere(
      child: GlassHeaderLayout(
        header: ArchiveHeaderBar(
          leading: GlassIconButton(
            icon: CupertinoIcons.back,
            label: '返回',
            onPressed: () => Navigator.pop(context),
          ),
          title: ArchiveRouteTitle(
            title: widget.title,
            code: 'IMAGE / ${_page + 1} OF ${widget.urls.length}',
          ),
          actions: [
            GlassIconButton(
              key: const ValueKey('book-image-save'),
              icon: CupertinoIcons.arrow_down_to_line,
              label: _saving ? '正在保存图片' : '保存图片',
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.maybePop(context),
          child: PageView.builder(
            key: const ValueKey('book-image-canvas'),
            controller: _pages,
            // InteractiveViewer owns both contacts from the first finger.
            // Its one-finger callbacks drive this PageView, so a small drift
            // before the second finger arrives cannot steal the pinch arena.
            physics: const NeverScrollableScrollPhysics(),
            // A drag activity ignores new pointers in its child subtree. Keep
            // paging under the image's recognizer so a second finger can land.
            pageSnapping: false,
            itemCount: widget.urls.length,
            onPageChanged: (page) => setState(() {
              _page = page;
            }),
            itemBuilder: (context, index) => _ZoomableBookImage(
              key: ValueKey((widget.urls[index], index)),
              onDragStart: _dragStart,
              onDragUpdate: _dragUpdate,
              onDragEnd: _dragEnd,
              onDragCancel: _dragCancel,
              onClose: () => Navigator.maybePop(context),
              child: SizedBox.expand(
                child: ReaderIllustration(
                  url: widget.urls[index],
                  cache: widget.cache,
                  fullScreen: true,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ZoomableBookImage extends StatefulWidget {
  const _ZoomableBookImage({
    super.key,
    required this.child,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.onClose,
  });
  final Widget child;
  final ValueChanged<ScaleStartDetails> onDragStart;
  final ValueChanged<ScaleUpdateDetails> onDragUpdate;
  final ValueChanged<ScaleEndDetails> onDragEnd;
  final VoidCallback onDragCancel;
  final VoidCallback onClose;
  @override
  State<_ZoomableBookImage> createState() => _ZoomableBookImageState();
}

class _ZoomableBookImageState extends State<_ZoomableBookImage>
    with SingleTickerProviderStateMixin {
  static const _initialScale = .9;
  final _transform = TransformationController();
  Size? _viewport;
  late final AnimationController _settle;
  void _applySettle() {
    if (_target != null) {
      _transform.value = _target!.lerp(
        NovelMotion.ease.transform(_settle.value),
      );
    }
  }

  Matrix4Tween? _target;
  // Keep the unused Z scale in step as InteractiveViewer uses the maximum
  // axis scale internally, including when the image is smaller than its fit.
  double get _scale => _transform.value.entry(0, 0).abs();
  Offset _tap = Offset.zero;
  final _contacts = <int>{};
  bool _multiple = false, _paging = false, _zoomed = false;
  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: NovelMotion.contact)
      ..addListener(_applySettle);
    _transform.addListener(_changed);
  }

  void _changed() {
    final zoomed = (_scale - _initialScale).abs() > .01;
    if (mounted && zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _animateTo(Matrix4 target) {
    _settle.stop();
    if (MediaQuery.disableAnimationsOf(context)) {
      _transform.value = target;
    } else {
      _target = Matrix4Tween(begin: _transform.value.clone(), end: target);
      _settle.forward(from: 0);
    }
  }

  Matrix4 _bounded(Size size, double scale, double x, double y) =>
      Matrix4.identity()
        ..translateByDouble(
          scale < 1
              ? size.width * (1 - scale) / 2
              : x.clamp(size.width * (1 - scale), 0),
          scale < 1
              ? size.height * (1 - scale) / 2
              : y.clamp(size.height * (1 - scale), 0),
          0,
          1,
        )
        ..scaleByDouble(scale, scale, scale, 1);
  @override
  void dispose() {
    _settle.dispose();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_viewport != size) {
        final scale = _viewport == null ? _initialScale : _scale;
        final translation = _transform.value.getTranslation();
        _viewport = size;
        _transform.value = _bounded(size, scale, translation.x, translation.y);
      }
      return Listener(
        onPointerDown: (event) {
          _contacts.add(event.pointer);
          if (_contacts.length > 1) {
            _multiple = true;
            _paging = false;
            widget.onDragCancel();
          }
        },
        onPointerUp: (event) => _contacts.remove(event.pointer),
        onPointerCancel: (event) => _contacts.remove(event.pointer),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onClose,
          onDoubleTapDown: (details) => _tap = details.localPosition,
          onDoubleTap: () {
            _animateTo(
              (_scale - _initialScale).abs() > .01
                  ? _bounded(size, _initialScale, 0, 0)
                  : _bounded(size, 2, -_tap.dx, -_tap.dy),
            );
          },
          child: InteractiveViewer(
            transformationController: _transform,
            panEnabled: _zoomed,
            minScale: .25,
            maxScale: 5,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            onInteractionStart: (details) {
              _settle.stop();
              _multiple = _contacts.length > 1 || details.pointerCount > 1;
              _paging = !_multiple && !_zoomed;
              if (_paging) widget.onDragStart(details);
            },
            onInteractionUpdate: (details) {
              if (details.pointerCount > 1) {
                _multiple = true;
                _paging = false;
                widget.onDragCancel();
              } else if (_paging && !_multiple) {
                widget.onDragUpdate(details);
              }
            },
            onInteractionEnd: (details) {
              if (_paging && !_multiple) widget.onDragEnd(details);
              _paging = false;
              final scale = _scale.clamp(.25, 5.0);
              final translation = _transform.value.getTranslation();
              _animateTo(_bounded(size, scale, translation.x, translation.y));
            },
            child: widget.child,
          ),
        ),
      );
    },
  );
}
