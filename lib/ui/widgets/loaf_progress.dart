/// Progress indicators that step slowly while motion is reduced: the stock
/// ones draw at the display's rate whatever the app asks, and on X11 every
/// frame copies the whole window through the CPU.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'still_when_unfocused.dart';

const _steps = 8;
const _stepEvery = Duration(milliseconds: 125);

/// A circle that spins; with [value], how far along. Use it in place of
/// [CircularProgressIndicator].
///
/// Indeterminate, it is the stock spinner while motion is on. Under reduced
/// motion it turns a quarter arc in eight steps a second on a timer, so it
/// draws eight frames a second instead of one per display refresh. While
/// the app is unfocused it holds still, and on focus it goes on from the
/// step it held. Stepping, it is announced as loading, never as an amount.
///
/// With [value] it is the stock determinate indicator: it only redraws when
/// the value changes.
class LoafSpinner extends StatefulWidget {
  const LoafSpinner({
    super.key,
    this.value,
    this.strokeWidth = 4,
    this.color,
    this.adaptive = false,
  });

  /// How far along, from 0 to 1; null while there is no telling.
  final double? value;

  /// As [CircularProgressIndicator.strokeWidth]; 4 is the stock default.
  final double strokeWidth;

  /// The arc's colour; null is the theme's, as the stock indicator picks it.
  final Color? color;

  /// The platform's own spinner while motion is on, as
  /// [CircularProgressIndicator.adaptive]. Under reduced motion every
  /// platform steps the same arc.
  final bool adaptive;

  @override
  State<LoafSpinner> createState() => _LoafSpinnerState();
}

class _LoafSpinnerState extends State<LoafSpinner> with _Stepping {
  @override
  bool get indeterminate => widget.value == null;

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    if (!indeterminate || !MediaQuery.disableAnimationsOf(context)) {
      return widget.adaptive
          ? CircularProgressIndicator.adaptive(
              value: widget.value,
              strokeWidth: widget.strokeWidth,
              valueColor: color == null ? null : AlwaysStoppedAnimation(color),
            )
          : CircularProgressIndicator(
              value: widget.value,
              strokeWidth: widget.strokeWidth,
              color: color,
            );
    }
    // A quarter arc, drawn as a fixed value so nothing ticks, turned a step
    // at a time.
    return _Loading(
      child: Transform.rotate(
        angle: step * 2 * math.pi / _steps,
        child: CircularProgressIndicator(
          value: 0.25,
          strokeWidth: widget.strokeWidth,
          color: color,
        ),
      ),
    );
  }
}

/// A bar that sweeps; with [value], how far along. Use it in place of
/// [LinearProgressIndicator].
///
/// Indeterminate, it is the stock bar while motion is on. Under reduced
/// motion a segment hops along the track in eight steps a second; while the
/// app is unfocused it holds, and it goes on from there on focus. Stepping,
/// it is announced as loading, never as an amount.
///
/// With [value] it is the stock determinate bar.
class LoafProgressBar extends StatefulWidget {
  const LoafProgressBar({
    super.key,
    this.value,
    this.minHeight,
    this.color,
    this.backgroundColor,
  });

  /// How far along, from 0 to 1; null while there is no telling.
  final double? value;

  /// As [LinearProgressIndicator.minHeight]; null is the stock 4.
  final double? minHeight;

  /// The bar's, or the hopping segment's, colour; null is the theme's.
  final Color? color;

  /// The track's colour; null is the theme's.
  final Color? backgroundColor;

  @override
  State<LoafProgressBar> createState() => _LoafProgressBarState();
}

class _LoafProgressBarState extends State<LoafProgressBar> with _Stepping {
  @override
  bool get indeterminate => widget.value == null;

  @override
  Widget build(BuildContext context) {
    if (!indeterminate || !MediaQuery.disableAnimationsOf(context)) {
      return LinearProgressIndicator(
        value: widget.value,
        minHeight: widget.minHeight,
        color: widget.color,
        backgroundColor: widget.backgroundColor,
      );
    }
    // The stock track, empty, with a segment hopping along it.
    return _Loading(
      child: Stack(
        children: [
          LinearProgressIndicator(
            value: 0,
            minHeight: widget.minHeight,
            color: widget.color,
            backgroundColor: widget.backgroundColor,
          ),
          Positioned.fill(
            child: Align(
              alignment: Alignment(-1 + step * 2 / (_steps - 1), 0),
              child: FractionallySizedBox(
                widthFactor: 0.3,
                heightFactor: 1,
                child: ColoredBox(
                  color:
                      widget.color ??
                      ProgressIndicatorTheme.of(context).color ??
                      Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Says what a stock indeterminate indicator says: loading, with no amount.
/// The fixed value drawn underneath would otherwise be read out as progress.
class _Loading extends StatelessWidget {
  const _Loading({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    role: SemanticsRole.loadingSpinner,
    child: ExcludeSemantics(child: child),
  );
}

/// Steps on a timer while indeterminate, motion is reduced and the app has
/// focus; keeps its step between runs, so it goes on from where it held.
mixin _Stepping<T extends StatefulWidget> on State<T> {
  var step = 0;
  Timer? _timer;

  bool get indeterminate;

  void _sync() {
    final run =
        indeterminate &&
        MediaQuery.disableAnimationsOf(context) &&
        StillWhenUnfocused.focusedOf(context);
    if (run && _timer == null) {
      _timer = Timer.periodic(
        _stepEvery,
        (_) => setState(() => step = (step + 1) % _steps),
      );
    } else if (!run) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(T old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
