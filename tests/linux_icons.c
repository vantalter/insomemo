// Exercise native icon transitions without requiring a window manager to
// restore layouts. Included here so timer state can be checked directly.
#include "../native/linux.c"
#include <assert.h>

void switcher_event(const char *kind, const char *first, const char *second) {
    (void)kind; (void)first; (void)second;
}
void switcher_context(const char *app, const char *title, const char *window, const char *site) {
    (void)app; (void)title; (void)window; (void)site;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    native_set_icon_theme(argv[1]);
    cinnamon_session = TRUE;
    native_update("context", 0, "", "[]", "{}");
    char *plain = g_strdup(icon_name());
    native_indicate_switch();
    assert(icon_state() == 1 && badge_timer);
    char *badged = g_strdup(icon_name());
    assert(strcmp(plain, badged));
    assert(strstr(badged, "insomemo-raster-0-1.png"));
    native_update("context", 1, "", "[]", "{}");
    assert(icon_state() == 2 && strcmp(badged, icon_name()));
    native_update("context", 0, "", "[]", "{}");
    assert(icon_state() == 1 && !strcmp(badged, icon_name()));
    g_source_remove(badge_timer);
    badge_timer = 0;
    assert(icon_state() == 0 && !strcmp(plain, icon_name()));
    g_free(plain);
    g_free(badged);
    for (int dark = 0; dark <= 1; dark++)
        for (int state = 0; state < 3; state++) {
            GVariant *pixmap = linux_icon_pixmap(dark, state);
            assert(g_variant_n_children(pixmap) == 1);
            GVariant *entry = g_variant_get_child_value(pixmap, 0), *bytes;
            int w, h;
            g_variant_get(entry, "(ii@ay)", &w, &h, &bytes);
            gsize length;
            const guchar *data = g_variant_get_fixed_array(bytes, &length, 1);
            assert(length == (gsize)w * h * 4);
            unsigned visible = 0;
            for (gsize i = 0; i < length; i += 4) {
                visible += data[i] > 0;
                assert(data[i + 1] == (dark ? 35 : 239));
                assert(data[i + 2] == (dark ? 38 : 240));
                assert(data[i + 3] == (dark ? 41 : 241));
            }
            assert(visible > 0 && visible < (unsigned)(w * h));
            if (state == 1) {
                int x = w * 82 / 100, y = h * 18 / 100;
                assert(data[(y * w + x) * 4] == 255); // badge center
            }
            assert(linux_icon_file(argv[1], dark, state));
            g_variant_unref(bytes);
            g_variant_unref(entry);
            g_variant_unref(pixmap);
        }
    puts("PASS: both inks, all raster states, fixed top-right badge and pause");
    return 0;
}
