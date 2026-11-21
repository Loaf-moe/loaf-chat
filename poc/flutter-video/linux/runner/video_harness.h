#ifndef RUNNER_VIDEO_HARNESS_H_
#define RUNNER_VIDEO_HARNESS_H_

#include <flutter_linux/flutter_linux.h>

// Registers the "poc/video" method channel on the view's engine:
//   start {tiles, width, height, fps, idle} -> [texture id, ...]
//   stats -> [frames delivered, pixel buffer copies]
//   stop  -> stops and joins every producer thread
void video_harness_register(FlView* view);

#endif  // RUNNER_VIDEO_HARNESS_H_
