#pragma once
#include <gio/gio.h>

/* state: 0 plain, 1 top-right badge, 2 paused. Returned variants
 * are new references; filenames live for the process lifetime. */
GVariant *linux_icon_pixmap(int dark, int state);
const char *linux_icon_file(const char *directory, int dark, int state);
