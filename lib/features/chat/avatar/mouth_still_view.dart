import 'package:flutter/widgets.dart';

import 'lip_sync.dart';

/// Shows one mouth still and fades to the next over [kMouthFadeMs].
///
/// The old still stays fully opaque underneath while the new one fades in on
/// top, so the circle never shows its background through the middle of the
/// fade. Both images were preloaded, so a change costs one opacity layer for
/// 50 ms and no decoding.
class MouthStillView extends StatefulWidget {
  const MouthStillView({
    super.key,
    required this.image,
    required this.size,
    this.fade = const Duration(milliseconds: kMouthFadeMs),
  });

  final ImageProvider image;
  final double size;
  final Duration fade;

  @override
  State<MouthStillView> createState() => _MouthStillViewState();
}

class _MouthStillViewState extends State<MouthStillView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: widget.fade,
    value: 1,
  );
  ImageProvider? _previous;

  @override
  void didUpdateWidget(MouthStillView old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) {
      _previous = old.image;
      _fade.duration = widget.fade;
      _fade.forward(from: 0).whenComplete(() {
        if (mounted && _fade.isCompleted) setState(() => _previous = null);
      });
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  Widget _still(ImageProvider image) => Image(
    image: image,
    fit: BoxFit.cover,
    width: widget.size,
    height: widget.size,
    gaplessPlayback: true,
  );

  @override
  Widget build(BuildContext context) {
    final previous = _previous;
    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (previous != null) _still(previous),
          FadeTransition(
            key: const ValueKey('mouth-still-fade'),
            opacity: _fade,
            child: _still(widget.image),
          ),
        ],
      ),
    );
  }
}
