# Motion budget — design

Loaf draws as few frames as it can. An idle window draws none; anything
that loops rests while the app is unfocused; and under reduced motion,
which is on by default under X11, loops either stop or step slowly.

## Why frames cost

- **Every frame is the whole window.** Flutter's Linux embedder has no
  partial repaint: one moving pixel re-renders the full window.
- **On X11, every frame goes through the CPU.** The embedder shares the
  frame with GTK by EGLImage only on Wayland (`fl_view_renderer.cc`); on
  X11 it reads the frame back with `glReadPixels`
  (`fl_compositor_opengl.cc`), uploads it again and draws it. Cost grows
  with window size.
- **Unfocused is not hidden.** The embedder reports `hidden` only for a
  withdrawn or iconified window (`fl_window_state_monitor.cc`). Switching
  i3 workspaces or focus reports `inactive`, and Flutter keeps drawing
  frames for anything that asks.

Measured on amdgpu under X11, Flutter 3.47.5, mock build, per-process GPU
time (see Measuring):

| What draws | Window | GPU | CPU |
|---|---|---|---|
| Sakura decor at 60 fps, focused | 2000×3600 | 28.8% | 38.0% |
| Sakura decor at 60 fps, focused | 900×1600 | 6.4% | 17.3% |
| Sakura decor at 60 fps, on a hidden workspace | 2160×3784 | 4.1% | 10.7% |
| Stock spinner, focused | 2000×3600 | 26.7% | 31.3% |
| `LoafSpinner` under reduced motion, focused | 2000×3600 | 3.7% | 6.0% |
| A hovered GIF (10 fps) | 1200×1600 | 2.7% | 8.5% |
| Anything, unfocused or idle | any | 0% | 0% |

## Decisions

- **Reduced motion is the one lever.** `MediaQuery.disableAnimations`
  carries every reason for less motion. Flutter's `Image` pauses GIFs on
  it, and loaf's looping widgets stop or step on it. `AnimationController`
  reads the platform flag instead, so one-shot animations (fades, scrolls)
  still finish: a message arriving while loaf is unfocused still appears.
- **Unfocused rests every loop.** Any lifecycle state but `resumed` counts
  as reduced motion.
- **A setting, on by default under X11.** Appearance → motion → "reduce
  motion". Never chosen, it follows the device: on when the window draws
  through X11, as GTK reports it, off elsewhere. Once chosen, the choice
  sticks either way.
- **Hover plays pictures.** Under reduced motion a GIF plays while the
  pointer is on it, and holds when the pointer leaves. Not while unfocused:
  a hidden window may never hear the pointer leave.
- **Two still looks for the 日本 decor.** Motion off by preference: no
  petals, the train parked at the right. Unfocused only: petals and train
  pause where they are and go on from there.
- **Spinners step.** Under reduced motion, indeterminate spinners and bars
  step eight times a second on a timer, about an eighth of the frames.
  Unfocused, they hold. Adaptive spinners show Material's arc under reduced
  motion on every platform. Stepping indicators are announced as loading,
  never as an amount.

## Pieces

- **`lib/ui/widgets/still_when_unfocused.dart`** — `StillWhenUnfocused`
  sits in `MaterialApp.builder` (`lib/main.dart`) and adds "unfocused" to
  reduced motion below it. `focusedOf` says whether the app has focus;
  `preferStillOf` says whether less motion is asked for by preference
  alone, read from the MediaQuery above it.
- **`lib/main.dart`** — the builder's outer MediaQuery folds the "reduce
  motion" setting into the system's request, above `StillWhenUnfocused`,
  so it counts as a preference.
- **`lib/platform/x11.dart`** + **`linux/runner/window_chrome.cc`** —
  `drawsThroughX11` asks the runner's `loaf/window` channel (`x11`), which
  answers from `GDK_IS_X11_DISPLAY`. False on every other platform.
- **`lib/ui/theme/appearance.dart`** — `AppearanceSettings.reduceMotion`
  is null until chosen; `AppearanceController.reduceMotion` falls back to
  the device default.
- **`lib/ui/widgets/plays_on_hover.dart`** — `PlaysOnHover` lifts reduced
  motion under the pointer while focused. Used by timeline media, the image
  viewer and link preview cards.
- **`lib/ui/widgets/loaf_progress.dart`** — `LoafSpinner` and
  `LoafProgressBar`, in place of the stock indeterminate indicators.
- **`lib/ui/theme/sakura.dart`** — petals and train read `preferStillOf`
  and `focusedOf`; their clocks keep their place across pauses.
- **`lib/ui/call/call_tile.dart`** — `Pulse` rests mid-breath under
  reduced motion.
- **`lib/ui/widgets/loaf_avatar.dart`** — `AvatarPicture` holds an animated
  avatar's current frame under reduced motion, once the current picture has
  shown one.

## Writing new motion

- Anything that loops reads `MediaQuery.disableAnimationsOf` and stops or
  steps, or is a Flutter widget that does (`Image`).
- Spinners and indeterminate bars are `LoafSpinner` and `LoafProgressBar`,
  never the stock indicators: those draw at the display's rate whatever
  reduced motion says.
- Stepping beats animating: a timer that calls `setState` draws one frame
  per step; a running ticker draws one per display refresh, even if nothing
  changed.
- A new reason for less motion enters as a MediaQuery above
  `StillWhenUnfocused`, so `preferStillOf` sees it.
- A paused clock keeps its place: on resume, motion goes on from where it
  held, not from the start.
- `PlaysOnHover` wraps outside any tap layer stacked over a picture: a
  `Stack` hit-tests only its topmost child.

## Measuring

Per-process GPU time from amdgpu's `drm-engine-gfx` counters, against a
profile build of the mock (`flutter build linux --profile
--dart-define=LOAF_BACKEND=mock`). The animated GIF is in "fermentation
nerds", under Home.

```sh
#!/bin/sh
# gpu.sh <pid> <seconds>: share of one GPU engine, and of one CPU
pid=$1; secs=$2
gfx() { cat /proc/$1/fdinfo/* 2>/dev/null | awk '/^drm-client-id/{id=$2} /^drm-engine-gfx:/{seen[id]=$2} END{s=0; for(k in seen) s+=seen[k]; print s}'; }
cpu() { awk '{print $14+$15}' /proc/$1/stat; }
g0=$(gfx $pid); c0=$(cpu $pid); sleep $secs; g1=$(gfx $pid); c1=$(cpu $pid)
awk -v g=$((g1-g0)) -v c=$((c1-c0)) -v s=$secs -v hz=$(getconf CLK_TCK) \
  'BEGIN{printf "gpu %.2f%%  cpu %.1f%%\n", g/(s*1e7), c*100/(hz*s)}'
```
