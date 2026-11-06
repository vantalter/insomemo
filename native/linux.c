#define _POSIX_C_SOURCE 200809L
#include "bridge.h"
#include <X11/XKBlib.h>
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <json-glib/json-glib.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

static GMainLoop *loop;
static GDBusConnection *bus;
static Display *display;
static Window active_window;
static int xkb_event;
static guint save_timer;
static guint revision = 1;
static char *tray_code, *tray_context, *tray_error;
static int tray_paused;
static JsonArray *tray_layouts;
static char *last_layouts;
static gboolean quit_requested;

static void emit(const char *kind, const char *first, const char *second) {
    switcher_event(kind, first ? first : "", second ? second : "");
}

static char *json_string(JsonNode *node) {
    JsonGenerator *generator = json_generator_new();
    json_generator_set_root(generator, node);
    char *data = json_generator_to_data(generator, NULL);
    g_object_unref(generator);
    return data;
}

void native_hash(const char *text, char *output) {
    char *hash = g_compute_checksum_for_string(G_CHECKSUM_SHA256, text, -1);
    memcpy(output, hash, 16);
    output[16] = 0;
    g_free(hash);
}
void native_free(char *value) { g_free(value); }

char *native_xkb_names(const char *layouts, const char *variants) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!context)
        return NULL;
    struct xkb_rule_names rules = {.layout = layouts, .variant = variants};
    struct xkb_keymap *keymap =
        xkb_keymap_new_from_names(context, &rules, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) {
        xkb_context_unref(context);
        return NULL;
    }
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_array(builder);
    for (xkb_layout_index_t i = 0; i < xkb_keymap_num_layouts(keymap); i++) {
        const char *name = xkb_keymap_layout_get_name(keymap, i);
        json_builder_add_string_value(builder, name ? name : "Unknown");
    }
    json_builder_end_array(builder);
    JsonNode *root = json_builder_get_root(builder);
    char *result = json_string(root);
    json_node_free(root);
    g_object_unref(builder);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    return result;
}

static int x_error(Display *d, XErrorEvent *e) {
    (void)d;
    if (e->error_code != BadWindow && e->error_code != BadMatch)
        fprintf(stderr, "input-switcher: X11 error %d\n", e->error_code);
    return 0;
}
static int ensure_display(void) {
    if (display)
        return 1;
    display = XOpenDisplay(NULL);
    if (display)
        XSetErrorHandler(x_error);
    return display != NULL;
}

static char *group_name(int group) {
    XkbDescPtr keyboard = XkbGetMap(display, 0, XkbUseCoreKbd);
    if (!keyboard)
        return NULL;
    XkbGetNames(display, XkbGroupNamesMask, keyboard);
    char *result = NULL;
    if (keyboard->names && group >= 0 && group < XkbNumKbdGroups &&
        keyboard->names->groups[group] != None) {
        char *name = XGetAtomName(display, keyboard->names->groups[group]);
        if (name) {
            result = g_strdup(name);
            XFree(name);
        }
    }
    XkbFreeKeyboard(keyboard, XkbAllComponentsMask, True);
    return result;
}

char *native_layouts(void) {
    if (!ensure_display())
        return NULL;
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_array(builder);
    for (int i = 0; i < XkbNumKbdGroups; i++) {
        char *name = group_name(i);
        if (!name)
            continue;
        char *id = g_strconcat("xkb:", name, NULL);
        char *code;
        if (strstr(name, "Ukrain"))
            code = g_strdup("UA");
        else if (strstr(name, "English"))
            code = g_strdup("EN");
        else {
            char *prefix = g_utf8_substring(name, 0, MIN(2, g_utf8_strlen(name, -1)));
            code = g_utf8_strup(prefix, -1);
            g_free(prefix);
        }
        json_builder_begin_object(builder);
        json_builder_set_member_name(builder, "id");
        json_builder_add_string_value(builder, id);
        json_builder_set_member_name(builder, "name");
        json_builder_add_string_value(builder, name);
        json_builder_set_member_name(builder, "code");
        json_builder_add_string_value(builder, code);
        json_builder_end_object(builder);
        g_free(name);
        g_free(id);
        g_free(code);
    }
    json_builder_end_array(builder);
    JsonNode *root = json_builder_get_root(builder);
    char *result = json_string(root);
    json_node_free(root);
    g_object_unref(builder);
    return result;
}

int native_set_layout(const char *id) {
    if (!display)
        return 0;
    for (int i = 0; i < XkbNumKbdGroups; i++) {
        char *name = group_name(i);
        if (!name)
            continue;
        char *candidate = g_strconcat("xkb:", name, NULL);
        int matches = strcmp(id, candidate) == 0;
        g_free(candidate);
        g_free(name);
        if (matches) {
            if (!XkbLockGroup(display, XkbUseCoreKbd, i))
                return 0;
            XSync(display, False);
            XkbStateRec state;
            return XkbGetState(display, XkbUseCoreKbd, &state) == Success && state.group == i;
        }
    }
    return 0;
}

static void read_layout(void) {
    XkbStateRec state;
    if (XkbGetState(display, XkbUseCoreKbd, &state) != Success)
        return;
    char *name = group_name(state.group);
    if (name) {
        char *id = g_strconcat("xkb:", name, NULL);
        emit("layout", id, "");
        g_free(id);
        g_free(name);
    }
}

static unsigned char *property(Window window, const char *name, Atom type, unsigned long *count) {
    Atom actual;
    int format;
    unsigned long after;
    unsigned char *data = NULL;
    if (XGetWindowProperty(display, window, XInternAtom(display, name, False), 0, 4096, False, type,
                           &actual, &format, count, &after, &data) != Success ||
        actual != type) {
        if (data)
            XFree(data);
        return NULL;
    }
    return data;
}

static void read_context(void) {
    Window root = DefaultRootWindow(display);
    unsigned long count = 0;
    unsigned char *data = property(root, "_NET_ACTIVE_WINDOW", XA_WINDOW, &count);
    Window window = data && count ? *(Window *)data : None;
    if (data)
        XFree(data);
    if (window == None) {
        int revert;
        XGetInputFocus(display, &window, &revert);
    }
    if (window == None || window == PointerRoot || window == root) {
        emit("context", "", "");
        return;
    }
    XClassHint hint = {0};
    // A focused widget may be a child of the WM_CLASS-bearing top-level window.
    for (int depth = 0; depth < 32; depth++) {
        if (XGetClassHint(display, window, &hint))
            break;
        Window tree_root, parent, *children = NULL;
        unsigned int n;
        if (!XQueryTree(display, window, &tree_root, &parent, &children, &n))
            break;
        if (children)
            XFree(children);
        if (parent == root || parent == None)
            break;
        window = parent;
    }
    if (window != active_window) {
        if (active_window)
            XSelectInput(display, active_window, NoEventMask);
        active_window = window;
        XSelectInput(display, window, PropertyChangeMask | FocusChangeMask | StructureNotifyMask);
    }
    data = property(window, "_NET_WM_NAME", XInternAtom(display, "UTF8_STRING", False), &count);
    char *title = data ? g_utf8_make_valid((char *)data, count) : NULL;
    if (data)
        XFree(data);
    if (!title) {
        char *legacy = NULL;
        if (XFetchName(display, window, &legacy) && legacy) {
            title = g_utf8_make_valid(legacy, -1);
            XFree(legacy);
        }
    }
    char *app = g_utf8_make_valid(
        hint.res_class ? hint.res_class : (hint.res_name ? hint.res_name : ""), -1);
    emit("context", app, title);
    g_free(app);
    g_free(title);
    if (hint.res_class)
        XFree(hint.res_class);
    if (hint.res_name)
        XFree(hint.res_name);
}

static gboolean x_events(gint fd, GIOCondition condition, gpointer user_data) {
    (void)fd;
    (void)user_data;
    if (condition & (G_IO_HUP | G_IO_ERR)) {
        emit("fatal", "X11 connection closed", "");
        return G_SOURCE_REMOVE;
    }
    while (XPending(display)) {
        XEvent event;
        XNextEvent(display, &event);
        if (event.type == xkb_event) {
            XkbEvent *xkb = (XkbEvent *)&event;
            if (xkb->any.xkb_type == XkbStateNotify)
                read_layout();
            else {
                emit("layouts", "", "");
                read_layout();
            }
        } else if (event.type == FocusIn || event.type == DestroyNotify) {
            read_context();
        } else if (event.type == PropertyNotify) {
            Atom atom = event.xproperty.atom;
            if (atom == XInternAtom(display, "_NET_ACTIVE_WINDOW", False) ||
                atom == XInternAtom(display, "_NET_WM_NAME", False) || atom == XA_WM_NAME ||
                atom == XA_WM_CLASS)
                read_context();
        }
    }
    return G_SOURCE_CONTINUE;
}

typedef struct {
    GSource source;
    GPollFD poll;
} XSource;
static gboolean x_prepare(GSource *source, gint *timeout) {
    (void)source;
    *timeout = -1;
    return XPending(display) > 0;
}
static gboolean x_check(GSource *source) {
    XSource *x = (XSource *)source;
    return x->poll.revents != 0 || XPending(display) > 0;
}
static gboolean x_dispatch(GSource *source, GSourceFunc callback, gpointer data) {
    (void)callback;
    (void)data;
    return x_events(((XSource *)source)->poll.fd, ((XSource *)source)->poll.revents, NULL);
}
static GSourceFuncs x_functions = {.prepare = x_prepare, .check = x_check, .dispatch = x_dispatch};

/* StatusNotifierItem + com.canonical.dbusmenu: no GTK/Qt, window, or webview. */
static const char *xml =
    "<node>"
    "<interface name='org.kde.StatusNotifierItem'>"
    "<property name='Category' type='s' access='read'/><property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/><property name='Status' type='s' "
    "access='read'/>"
    "<property name='WindowId' type='i' access='read'/><property name='IconName' type='s' "
    "access='read'/>"
    "<property name='IconPixmap' type='a(iiay)' access='read'/><property name='IconThemePath' "
    "type='s' access='read'/>"
    "<property name='AttentionIconName' type='s' access='read'/><property "
    "name='AttentionIconPixmap' type='a(iiay)' access='read'/>"
    "<property name='AttentionMovieName' type='s' access='read'/><property name='OverlayIconName' "
    "type='s' access='read'/>"
    "<property name='OverlayIconPixmap' type='a(iiay)' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/><property name='Menu' type='o' "
    "access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/>"
    "<property name='XAyatanaLabel' type='s' access='read'/><property name='XAyatanaLabelGuide' "
    "type='s' access='read'/>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' "
    "direction='in'/></method>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' "
    "direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<signal name='NewTitle'/><signal name='NewIcon'/><signal name='NewToolTip'/>"
    "<signal name='NewStatus'><arg type='s'/></signal>"
    "<signal name='XAyatanaNewLabel'><arg type='s'/><arg type='s'/></signal>"
    "</interface>"
    "<interface name='com.canonical.dbusmenu'>"
    "<property name='Version' type='u' access='read'/><property name='TextDirection' type='s' "
    "access='read'/>"
    "<property name='Status' type='s' access='read'/><property name='IconThemePath' type='as' "
    "access='read'/>"
    "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg "
    "type='as' direction='in'/>"
    "<arg type='u' direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>"
    "<method name='GetGroupProperties'><arg type='ai' direction='in'/><arg type='as' "
    "direction='in'/><arg type='a(ia{sv})' direction='out'/></method>"
    "<method name='GetProperty'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg "
    "type='v' direction='out'/></method>"
    "<method name='Event'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg "
    "type='v' direction='in'/><arg type='u' direction='in'/></method>"
    "<method name='EventGroup'><arg type='a(isvu)' direction='in'/><arg type='ai' "
    "direction='out'/></method>"
    "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' "
    "direction='out'/></method>"
    "<method name='AboutToShowGroup'><arg type='ai' direction='in'/><arg type='ai' "
    "direction='out'/><arg type='ai' direction='out'/></method>"
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "<signal name='ItemsPropertiesUpdated'><arg type='a(ia{sv})'/><arg type='a(ias)'/></signal>"
    "</interface></node>";

static GVariant *empty_pixmap(void) {
    return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0);
}
static GVariant *properties(int id) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    const char *label = "";
    char *allocated = NULL;
    gboolean enabled = TRUE;
    switch (id) {
    case 0:
        break;
    case 1:
        allocated = g_strconcat("Active Context: ", tray_context ? tray_context : "—", NULL);
        label = allocated;
        enabled = FALSE;
        break;
    case 2:
        label = tray_paused ? "Resume Auto-Switching" : "Pause Auto-Switching";
        break;
    case 3:
        label = "Force Default Layout";
        g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
        break;
    case 4:
        label = "Clear Cache";
        break;
    case 5:
        label = "Quit";
        break;
    case 6:
        label = tray_error ? tray_error : "";
        enabled = FALSE;
        break;
    default:
        if (id >= 100 && tray_layouts && (guint)(id - 100) < json_array_get_length(tray_layouts))
            label = json_object_get_string_member(
                json_array_get_object_element(tray_layouts, id - 100), "name");
        else
            enabled = FALSE;
    }
    g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(label));
    g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(enabled));
    g_variant_builder_add(&props, "{sv}", "visible",
                          g_variant_new_boolean(id != 6 || (tray_error && *tray_error)));
    g_free(allocated);
    return g_variant_builder_end(&props);
}

static GVariant *menu_node(int id, int depth) {
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    if (depth != 0) {
        int next = depth > 0 ? depth - 1 : -1;
        if (id == 0) {
            int ids[] = {1, 6, 2, 3, 4, 5};
            for (size_t i = 0; i < G_N_ELEMENTS(ids); i++)
                g_variant_builder_add(&children, "v", menu_node(ids[i], next));
        }
        if (id == 3 && tray_layouts)
            for (guint i = 0; i < json_array_get_length(tray_layouts); i++)
                g_variant_builder_add(&children, "v", menu_node(100 + i, next));
    }
    return g_variant_new("(i@a{sv}@av)", id, properties(id), g_variant_builder_end(&children));
}

static void clicked(int id, const char *event) {
    if (strcmp(event, "clicked"))
        return;
    if (id == 2)
        emit("pause", "", "");
    if (id == 4)
        emit("clear", "", "");
    if (id == 5)
        emit("quit", "", "");
    if (id >= 100 && tray_layouts && (guint)(id - 100) < json_array_get_length(tray_layouts)) {
        char *layout = g_strdup(json_object_get_string_member(
            json_array_get_object_element(tray_layouts, id - 100), "id"));
        emit("default", layout, "");
        g_free(layout);
    }
}

static void method_call(GDBusConnection *connection, const gchar *sender, const gchar *path,
                        const gchar *interface, const gchar *method, GVariant *parameters,
                        GDBusMethodInvocation *invocation, gpointer user_data) {
    (void)connection;
    (void)sender;
    (void)path;
    (void)user_data;
    if (!strcmp(interface, "org.kde.StatusNotifierItem")) {
        if (!strcmp(method, "SecondaryActivate"))
            emit("pause", "", "");
        g_dbus_method_invocation_return_value(invocation, NULL);
        return;
    }
    if (!strcmp(method, "GetLayout")) {
        gint id, depth;
        GVariant *names;
        g_variant_get(parameters, "(ii@as)", &id, &depth, &names);
        g_variant_unref(names);
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(u@(ia{sv}av))", revision, menu_node(id, depth)));
    } else if (!strcmp(method, "AboutToShow")) {
        emit("layouts", "", "");
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", TRUE));
    } else if (!strcmp(method, "AboutToShowGroup")) {
        emit("layouts", "", "");
        GVariant *ids = g_variant_get_child_value(parameters, 0);
        g_dbus_method_invocation_return_value(
            invocation,
            g_variant_new("(@ai@ai)", ids, g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    } else if (!strcmp(method, "GetGroupProperties")) {
        GVariant *ids = g_variant_get_child_value(parameters, 0);
        GVariantIter iter;
        gint id;
        GVariantBuilder result;
        g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
        g_variant_iter_init(&iter, ids);
        while (g_variant_iter_next(&iter, "i", &id))
            g_variant_builder_add(&result, "(i@a{sv})", id, properties(id));
        g_variant_unref(ids);
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&result)));
    } else if (!strcmp(method, "GetProperty")) {
        gint id;
        const char *name;
        g_variant_get(parameters, "(i&s)", &id, &name);
        GVariant *props = g_variant_ref_sink(properties(id));
        GVariant *value = g_variant_lookup_value(props, name, NULL);
        if (value) {
            g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", value));
            g_variant_unref(value);
        } else
            g_dbus_method_invocation_return_dbus_error(
                invocation, "com.canonical.dbusmenu.Error.UnknownProperty", "Unknown property");
        g_variant_unref(props);
    } else if (!strcmp(method, "Event")) {
        gint id;
        const char *event;
        GVariant *data;
        guint timestamp;
        g_variant_get(parameters, "(i&s@vu)", &id, &event, &data, &timestamp);
        clicked(id, event);
        g_variant_unref(data);
        g_dbus_method_invocation_return_value(invocation, NULL);
    } else if (!strcmp(method, "EventGroup")) {
        GVariant *events = g_variant_get_child_value(parameters, 0);
        GVariantIter iter;
        gint id;
        const char *event;
        GVariant *data;
        guint timestamp;
        g_variant_iter_init(&iter, events);
        while (g_variant_iter_next(&iter, "(i&s@vu)", &id, &event, &data, &timestamp)) {
            clicked(id, event);
            g_variant_unref(data);
        }
        g_variant_unref(events);
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    } else
        g_dbus_method_invocation_return_dbus_error(
            invocation, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
}

static GVariant *get_property(GDBusConnection *connection, const gchar *sender, const gchar *path,
                              const gchar *interface, const gchar *name, GError **error,
                              gpointer user_data) {
    (void)connection;
    (void)sender;
    (void)path;
    (void)error;
    (void)user_data;
    if (!strcmp(interface, "com.canonical.dbusmenu")) {
        if (!strcmp(name, "Version"))
            return g_variant_new_uint32(3);
        if (!strcmp(name, "TextDirection"))
            return g_variant_new_string("ltr");
        if (!strcmp(name, "Status"))
            return g_variant_new_string("normal");
        return g_variant_new_strv(NULL, 0);
    }
    if (!strcmp(name, "Category"))
        return g_variant_new_string("SystemServices");
    if (!strcmp(name, "Id"))
        return g_variant_new_string("input-switcher");
    if (!strcmp(name, "Title") || !strcmp(name, "XAyatanaLabel"))
        return g_variant_new_string(tray_code ? tray_code : "--");
    if (!strcmp(name, "XAyatanaLabelGuide"))
        return g_variant_new_string("XX");
    if (!strcmp(name, "Status"))
        return g_variant_new_string("Active");
    if (!strcmp(name, "WindowId"))
        return g_variant_new_int32(0);
    if (!strcmp(name, "IconName"))
        return g_variant_new_string(tray_paused ? "media-playback-pause-symbolic"
                                                : "input-keyboard-symbolic");
    if (g_str_has_suffix(name, "Pixmap"))
        return empty_pixmap();
    if (!strcmp(name, "ToolTip"))
        return g_variant_new("(s@a(iiay)ss)", "input-keyboard-symbolic", empty_pixmap(),
                             tray_code ? tray_code : "Input Switcher",
                             tray_context ? tray_context : "");
    if (!strcmp(name, "Menu"))
        return g_variant_new_object_path("/MenuBar");
    if (!strcmp(name, "ItemIsMenu"))
        return g_variant_new_boolean(TRUE);
    return g_variant_new_string("");
}
static const GDBusInterfaceVTable vtable = {.method_call = method_call,
                                            .get_property = get_property};

static void registration_done(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    if (reply)
        g_variant_unref(reply);
    if (error) {
        emit("error", error->message, "");
        g_error_free(error);
    }
}
static void watcher_appeared(GDBusConnection *connection, const gchar *name, const gchar *owner,
                             gpointer data) {
    (void)name;
    (void)owner;
    (void)data;
    g_dbus_connection_call(connection, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                           "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
                           g_variant_new("(s)", "/StatusNotifierItem"), NULL,
                           G_DBUS_CALL_FLAGS_NONE, 2000, NULL, registration_done, NULL);
}
static void watcher_vanished(GDBusConnection *connection, const gchar *name, gpointer data) {
    (void)connection;
    (void)name;
    (void)data;
    fprintf(
        stderr,
        "input-switcher: no StatusNotifier tray host; daemon remains active (SIGTERM to quit)\n");
}

void native_update(const char *code, const char *context, int paused, const char *error,
                   const char *layouts_json) {
    gboolean changed = g_strcmp0(tray_code, code) || g_strcmp0(tray_context, context) ||
                       g_strcmp0(tray_error, error) || tray_paused != paused ||
                       g_strcmp0(last_layouts, layouts_json);
    if (!changed)
        return;
    g_free(tray_code);
    tray_code = g_strdup(code);
    g_free(tray_context);
    tray_context = g_strdup(context);
    g_free(tray_error);
    tray_error = g_strdup(error);
    tray_paused = paused;
    if (g_strcmp0(last_layouts, layouts_json)) {
        JsonParser *parser = json_parser_new();
        if (json_parser_load_from_data(parser, layouts_json, -1, NULL)) {
            if (tray_layouts)
                json_array_unref(tray_layouts);
            tray_layouts = json_array_ref(json_node_get_array(json_parser_get_root(parser)));
        }
        g_object_unref(parser);
        g_free(last_layouts);
        last_layouts = g_strdup(layouts_json);
    }
    revision++;
    if (bus) {
        const char *signals[] = {"NewTitle", "NewIcon", "NewToolTip"};
        for (size_t i = 0; i < G_N_ELEMENTS(signals); i++)
            g_dbus_connection_emit_signal(bus, NULL, "/StatusNotifierItem",
                                          "org.kde.StatusNotifierItem", signals[i], NULL, NULL);
        g_dbus_connection_emit_signal(bus, NULL, "/StatusNotifierItem",
                                      "org.kde.StatusNotifierItem", "XAyatanaNewLabel",
                                      g_variant_new("(ss)", code, "XX"), NULL);
        g_dbus_connection_emit_signal(bus, NULL, "/MenuBar", "com.canonical.dbusmenu",
                                      "LayoutUpdated", g_variant_new("(ui)", revision, 0), NULL);
    }
}

static gboolean save(gpointer data) {
    (void)data;
    save_timer = 0;
    emit("flush", "", "");
    return G_SOURCE_REMOVE;
}
void native_schedule_save(void) {
    if (save_timer)
        g_source_remove(save_timer);
    save_timer = g_timeout_add(2000, save, NULL);
}
void native_stop(void) {
    quit_requested = TRUE;
    if (loop)
        g_main_loop_quit(loop);
}
static gboolean terminate(gpointer data) {
    (void)data;
    emit("quit", "", "");
    return G_SOURCE_REMOVE;
}
static gboolean wayland_ready(gint fd, GIOCondition condition, gpointer data) {
    (void)fd;
    (void)data;
    if (condition & (G_IO_HUP | G_IO_ERR)) {
        emit("fatal", "Compositor connection closed", "");
        return G_SOURCE_REMOVE;
    }
    emit("io", "", "");
    return G_SOURCE_CONTINUE;
}

int native_run(int event_fd) {
    loop = g_main_loop_new(NULL, FALSE);
    GError *error = NULL;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(xml, NULL);
    if (bus) {
        if (!g_dbus_connection_register_object(bus, "/StatusNotifierItem", info->interfaces[0],
                                               &vtable, NULL, NULL, &error) ||
            !g_dbus_connection_register_object(bus, "/MenuBar", info->interfaces[1], &vtable, NULL,
                                               NULL, &error)) {
            emit("error", error ? error->message : "Cannot register system tray", "");
            g_clear_error(&error);
        }
        g_bus_watch_name_on_connection(bus, "org.kde.StatusNotifierWatcher",
                                       G_BUS_NAME_WATCHER_FLAGS_NONE, watcher_appeared,
                                       watcher_vanished, NULL, NULL);
    } else {
        emit("error", error ? error->message : "Session D-Bus unavailable", "");
        g_clear_error(&error);
    }
    g_dbus_node_info_unref(info);
    g_unix_signal_add(SIGINT, terminate, NULL);
    g_unix_signal_add(SIGTERM, terminate, NULL);
    if (event_fd >= 0) {
        g_unix_fd_add(event_fd, G_IO_IN | G_IO_HUP | G_IO_ERR, wayland_ready, NULL);
        emit("ready", "", "");
    } else {
        if (!ensure_display()) {
            emit("error", "Cannot open X11 display", "");
            return 1;
        }
        int opcode, error_base, major = XkbMajorVersion, minor = XkbMinorVersion;
        if (!XkbQueryExtension(display, &opcode, &xkb_event, &error_base, &major, &minor)) {
            emit("error", "XKB extension unavailable", "");
            return 1;
        }
        XkbSelectEvents(
            display, XkbUseCoreKbd,
            XkbStateNotifyMask | XkbNamesNotifyMask | XkbNewKeyboardNotifyMask | XkbMapNotifyMask,
            XkbStateNotifyMask | XkbNamesNotifyMask | XkbNewKeyboardNotifyMask | XkbMapNotifyMask);
        XkbSelectEventDetails(display, XkbUseCoreKbd, XkbStateNotify, XkbAllStateComponentsMask,
                              XkbGroupStateMask);
        XSelectInput(display, DefaultRootWindow(display), PropertyChangeMask | FocusChangeMask);
        GSource *source = g_source_new(&x_functions, sizeof(XSource));
        XSource *x = (XSource *)source;
        x->poll.fd = ConnectionNumber(display);
        x->poll.events = G_IO_IN | G_IO_HUP | G_IO_ERR;
        g_source_add_poll(source, &x->poll);
        g_source_attach(source, NULL);
        g_source_unref(source);
        emit("ready", "", "");
        read_layout();
        read_context();
        XFlush(display);
        // Xlib synchronous queries may already have buffered notifications.
        x_events(ConnectionNumber(display), G_IO_IN, NULL);
    }
    if (!quit_requested)
        g_main_loop_run(loop);
    if (bus)
        g_dbus_connection_flush_sync(bus, NULL, NULL);
    if (display) {
        XCloseDisplay(display);
        display = NULL;
    }
    g_main_loop_unref(loop);
    loop = NULL;
    return 0;
}
