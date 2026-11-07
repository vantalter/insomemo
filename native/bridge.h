#pragma once
#include <stddef.h>

/* All callbacks and native calls run on the OS main-loop thread. Strings are
 * borrowed for the duration of the call, except native_layouts (caller frees). */
void switcher_event(const char *kind, const char *first, const char *second);
void switcher_context(const char *app, const char *title, const char *window_id, int address_bar);
int native_run(int event_fd);
int native_set_layout(const char *id);
char *native_layouts(void);
void native_free(char *value);
void native_update(const char *context, int paused, const char *error, const char *layouts_json);
void native_schedule_save(void);
void native_stop(void);
void native_hash(const char *text, char *output);
