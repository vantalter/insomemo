#include "linux_icon.h"
#include "tray_icon.h"
#include <gdk-pixbuf/gdk-pixbuf.h>

static GdkPixbuf *icons[2][4];
static GVariant *pixmaps[2][4];
static char *filenames[2][4];

static GdkPixbuf *icon(int dark, int state) {
    if (icons[dark][state])
        return icons[dark][state];
    GInputStream *stream = g_memory_input_stream_new_from_data(tray_icon, sizeof tray_icon, NULL);
    GError *error = NULL;
    GdkPixbuf *image = gdk_pixbuf_new_from_stream(stream, NULL, &error);
    g_object_unref(stream);
    if (!image) {
        g_warning("Cannot decode Insomemo tray icon: %s", error->message);
        g_error_free(error);
        return NULL;
    }
    // The bundled RGBA mask is used by macOS too. Only its alpha is needed.
    if (!gdk_pixbuf_get_has_alpha(image) || gdk_pixbuf_get_n_channels(image) != 4) {
        g_object_unref(image);
        return NULL;
    }
    int width = gdk_pixbuf_get_width(image), height = gdk_pixbuf_get_height(image);
    int stride = gdk_pixbuf_get_rowstride(image);
    guchar *pixels = gdk_pixbuf_get_pixels(image);
    const guchar light[] = {239, 240, 241}, dark_rgb[] = {35, 38, 41};
    const guchar *rgb = dark ? dark_rgb : light;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            guchar *p = pixels + y * stride + x * 4;
            if (state == 3) {
                p[3] = y >= height / 5 && y < height * 4 / 5 &&
                               ((x >= width / 4 && x < width * 5 / 12) ||
                                (x >= width * 7 / 12 && x < width * 3 / 4))
                           ? 255 : 0;
            } else if (state) {
                // Supersample the badge edges; the surrounding ring is clear.
                double radius = width * 0.18, outer = radius + width * 0.08;
                double cx = width - radius, cy = state == 1 ? radius : height - radius;
                unsigned alpha = 0;
                for (int sy = 0; sy < 4; sy++)
                    for (int sx = 0; sx < 4; sx++) {
                        double dx = x + (sx + 0.5) / 4 - cx;
                        double dy = y + (sy + 0.5) / 4 - cy;
                        double d = dx * dx + dy * dy;
                        alpha += d <= radius * radius ? 255 : d <= outer * outer ? 0 : p[3];
                    }
                p[3] = (alpha + 8) / 16;
            }
            p[0] = rgb[0]; p[1] = rgb[1]; p[2] = rgb[2];
        }
    }
    icons[dark][state] = image;
    return image;
}

GVariant *linux_icon_pixmap(int dark, int state) {
    if (pixmaps[dark][state])
        return g_variant_ref(pixmaps[dark][state]);
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a(iiay)"));
    GdkPixbuf *image = icon(dark, state);
    if (image) {
        int width = gdk_pixbuf_get_width(image), height = gdk_pixbuf_get_height(image);
        int stride = gdk_pixbuf_get_rowstride(image);
        const guchar *pixels = gdk_pixbuf_read_pixels(image);
        gsize length = (gsize)width * height * 4;
        guchar *argb = g_malloc(length);
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++) {
                const guchar *p = pixels + y * stride + x * 4;
                guchar *out = argb + ((gsize)y * width + x) * 4;
                // SNI specifies bytes in network ARGB order, not native endian.
                out[0] = p[3]; out[1] = p[0]; out[2] = p[1]; out[3] = p[2];
            }
        GVariant *bytes = g_variant_new_from_data(G_VARIANT_TYPE("ay"), argb, length,
                                                  TRUE, g_free, argb);
        g_variant_builder_add(&builder, "(ii@ay)", width, height, bytes);
    }
    pixmaps[dark][state] = g_variant_ref_sink(g_variant_builder_end(&builder));
    return g_variant_ref(pixmaps[dark][state]);
}

const char *linux_icon_file(const char *directory, int dark, int state) {
    if (filenames[dark][state])
        return filenames[dark][state];
    if (!directory || !g_path_is_absolute(directory))
        return NULL;
    GdkPixbuf *image = icon(dark, state);
    gchar *buffer = NULL;
    gsize length = 0;
    GError *error = NULL;
    if (!image || !gdk_pixbuf_save_to_buffer(image, &buffer, &length, "png", &error, NULL)) {
        g_clear_error(&error);
        return NULL;
    }
    char *name = g_strdup_printf("insomemo-raster-%d-%d.png", dark, state);
    char *path = g_build_filename(directory, name, NULL);
    g_free(name);
    // GLib replaces the file atomically, avoiding partially read PNGs at restart.
    if (g_file_set_contents(path, buffer, length, &error))
        filenames[dark][state] = path;
    else {
        g_warning("Cannot write tray PNG: %s", error->message);
        g_error_free(error);
        g_free(path);
    }
    g_free(buffer);
    return filenames[dark][state];
}
