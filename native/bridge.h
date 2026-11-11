#pragma once
#include <stddef.h>

/* All callbacks and native calls run on the OS main-loop thread. Strings are
 * borrowed for the duration of the call, except native_layouts (caller frees). */
void switcher_event(const char *kind, const char *first, const char *second);
void switcher_context(const char *app, const char *title, const char *window_id,
                      const char *site);
int native_run(int event_fd);
int native_set_layout(const char *id);
char *native_layouts(void);
void native_free(char *value);
void native_update(const char *context, int paused, const char *error, const char *layouts_json,
                   const char *menu_json);
void native_schedule_save(void);
/* Badge the tray icon briefly; repeated calls extend one badge, not restart it. */
void native_indicate_switch(void);
/* Linux: directory of Insomemo's symbolic tray icons (StatusNotifier IconThemePath). */
void native_set_icon_theme(const char *path);
/* Linux: 1 selects the dark-ink icons for light panels, 0 the light ones. */
void native_set_icon_ink(int dark);
/* macOS: -1 queries, 0 disables, 1 enables Launch at Login. Returns -1 when
 * unsupported, 0 off, 1 on, 2 awaiting approval in System Settings. */
int native_login_item(int action);
void native_stop(void);
void native_hash(const char *text, char *output);
void native_alert(const char *message); /* macOS only; blocks until dismissed */
