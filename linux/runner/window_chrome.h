#ifndef RUNNER_WINDOW_CHROME_H_
#define RUNNER_WINDOW_CHROME_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Hides GTK's title bar, keeping its client-side shadows and resize edges,
// and answers Loaf's own window buttons over the `loaf/window` channel.
// Call before the window is realized. Lives as long as |window|.
void window_chrome_attach(GtkWindow* window, FlView* view);

#endif  // RUNNER_WINDOW_CHROME_H_
