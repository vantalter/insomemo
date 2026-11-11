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
static Atom net_active_window, net_wm_name, utf8_string;
static int xkb_event;
static guint save_timer;
static guint revision = 1;
static char *tray_context, *tray_error;
static int tray_paused;
static JsonArray *tray_layouts;
static char *last_layouts;
static JsonObject *tray_menu; /* pin/forget scopes, labelled by Rust */
static char *last_menu;
static guint badge_timer;       /* nonzero while the switch indicator shows */
static char *icon_theme_path;   /* Insomemo's symbolic icons; NULL uses the theme */
static int dark_ink;            /* dark-ink icons, for light panels */
static char *cinnamon_theme;    /* Cinnamon's theme name; NULL outside Cinnamon */
static guint32 color_scheme;    /* portal preference: 0 none, 1 dark, 2 light */
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
        fprintf(stderr, "insomemo: X11 error %d\n", e->error_code);
    return 0;
}
static int x_io_error(Display *d) {
    (void)d;
    fprintf(stderr, "insomemo: X11 connection lost\n");
    // Xlib exits the process when this handler returns; flush learned layouts first.
    emit("quit", "", "");
    return 0;
}
static int ensure_display(void) {
    if (display)
        return 1;
    display = XOpenDisplay(NULL);
    if (display) {
        XSetErrorHandler(x_error);
        XSetIOErrorHandler(x_io_error);
        // Looked up once: property events are compared against these.
        net_active_window = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
        net_wm_name = XInternAtom(display, "_NET_WM_NAME", False);
        utf8_string = XInternAtom(display, "UTF8_STRING", False);
    }
    return display != NULL;
}

/* Fills names[group] for every XKB group (NULL where unset) from one keyboard
 * description, instead of fetching the description once per group. */
static void group_names(char *names[XkbNumKbdGroups]) {
    memset(names, 0, sizeof(char *) * XkbNumKbdGroups);
    XkbDescPtr keyboard = XkbGetMap(display, 0, XkbUseCoreKbd);
    if (!keyboard)
        return;
    if (XkbGetNames(display, XkbGroupNamesMask, keyboard) == Success && keyboard->names)
        for (int i = 0; i < XkbNumKbdGroups; i++) {
            if (keyboard->names->groups[i] == None)
                continue;
            char *name = XGetAtomName(display, keyboard->names->groups[i]);
            if (name) {
                names[i] = g_strdup(name);
                XFree(name);
            }
        }
    XkbFreeKeyboard(keyboard, XkbAllComponentsMask, True);
}
static void free_group_names(char *names[XkbNumKbdGroups]) {
    for (int i = 0; i < XkbNumKbdGroups; i++)
        g_free(names[i]);
}

char *native_layouts(void) {
    if (!ensure_display())
        return NULL;
    char *names[XkbNumKbdGroups];
    group_names(names);
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_array(builder);
    for (int i = 0; i < XkbNumKbdGroups; i++) {
        const char *name = names[i];
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
        g_free(id);
        g_free(code);
    }
    free_group_names(names);
    json_builder_end_array(builder);
    JsonNode *root = json_builder_get_root(builder);
    char *result = json_string(root);
    json_node_free(root);
    g_object_unref(builder);
    return result;
}

int native_set_layout(const char *id) {
    if (!display || strncmp(id, "xkb:", 4))
        return 0;
    char *names[XkbNumKbdGroups];
    group_names(names);
    int group = -1;
    for (int i = 0; i < XkbNumKbdGroups && group < 0; i++)
        if (names[i] && !strcmp(id + 4, names[i]))
            group = i;
    free_group_names(names);
    if (group < 0 || !XkbLockGroup(display, XkbUseCoreKbd, group))
        return 0;
    XSync(display, False);
    XkbStateRec state;
    return XkbGetState(display, XkbUseCoreKbd, &state) == Success && state.group == group;
}

static void read_layout(void) {
    XkbStateRec state;
    if (XkbGetState(display, XkbUseCoreKbd, &state) != Success || state.group >= XkbNumKbdGroups)
        return;
    char *names[XkbNumKbdGroups];
    group_names(names);
    if (names[state.group]) {
        char *id = g_strconcat("xkb:", names[state.group], NULL);
        emit("layout", id, "");
        g_free(id);
    }
    free_group_names(names);
}

static unsigned char *property(Window window, Atom name, Atom type, unsigned long *count) {
    Atom actual;
    int format;
    unsigned long after;
    unsigned char *data = NULL;
    if (XGetWindowProperty(display, window, name, 0, 4096, False, type,
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
    unsigned char *data = property(root, net_active_window, XA_WINDOW, &count);
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
    data = property(window, net_wm_name, utf8_string, &count);
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
            if (atom == net_active_window || atom == net_wm_name || atom == XA_WM_NAME ||
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
static JsonArray *menu_scopes(void) {
    return tray_menu && json_object_has_member(tray_menu, "scopes")
               ? json_object_get_array_member(tray_menu, "scopes")
               : NULL;
}
static guint scope_count(void) {
    JsonArray *scopes = menu_scopes();
    return scopes ? json_array_get_length(scopes) : 0;
}
static JsonObject *menu_scope(int index) {
    return index >= 0 && (guint)index < scope_count()
               ? json_array_get_object_element(menu_scopes(), index)
               : NULL;
}

/* Switch Indicator submenu: labels and the values sent to Rust. */
enum { INDICATOR_OFF = 600 };
static const char *const indicator_choices[][2] = {
    {"Off", "off"}, {"Top Right", "top-right"}, {"Bottom Right", "bottom-right"}};
static const char *indicator_position(void) {
    return tray_menu && json_object_has_member(tray_menu, "indicator_position")
               ? json_object_get_string_member(tray_menu, "indicator_position")
               : "top-right";
}
static const char *indicator_choice(void) {
    return tray_menu && json_object_get_boolean_member(tray_menu, "indicator")
               ? indicator_position()
               : "off";
}

static GVariant *properties(int id) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    const char *label = "";
    char *allocated = NULL;
    gboolean enabled = TRUE;
    switch (id) {
    case 0:
        // Enlightenment opens the menu on click only when the root says it has one.
        g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
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
    case 7:
        label = tray_menu ? json_object_get_string_member(tray_menu, "pin_title")
                          : "Always Use Current Layout In";
        enabled = scope_count() > 0;
        g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
        break;
    case 8:
        label = "Forget Learned Layout";
        enabled = scope_count() > 0;
        g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
        break;
    case 10:
        label = "Switch Indicator";
        g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
        break;
    case INDICATOR_OFF:
    case INDICATOR_OFF + 1:
    case INDICATOR_OFF + 2: {
        const char *const *choice = indicator_choices[id - INDICATOR_OFF];
        label = choice[0];
        g_variant_builder_add(&props, "{sv}", "toggle-type", g_variant_new_string("radio"));
        g_variant_builder_add(&props, "{sv}", "toggle-state",
                              g_variant_new_int32(!strcmp(indicator_choice(), choice[1])));
        break;
    }
    case 11: {
        const char *login = tray_menu ? json_object_get_string_member(tray_menu, "login") : NULL;
        label = "Launch at Login";
        g_variant_builder_add(&props, "{sv}", "toggle-type", g_variant_new_string("checkmark"));
        g_variant_builder_add(&props, "{sv}", "toggle-state",
                              g_variant_new_int32(!g_strcmp0(login, "on")));
        break;
    }
    case 9: {
        gint64 pins = tray_menu ? json_object_get_int_member(tray_menu, "pins") : 0;
        allocated = pins ? g_strdup_printf("Remove All Pins (%" G_GINT64_FORMAT ")", pins)
                         : g_strdup("Remove All Pins");
        label = allocated;
        enabled = pins > 0;
        break;
    }
    default:
        if (id >= 200 && id < 300 && menu_scope(id - 200)) {
            JsonObject *scope = menu_scope(id - 200);
            label = json_object_get_string_member(scope, "pin_label");
            g_variant_builder_add(&props, "{sv}", "toggle-type", g_variant_new_string("checkmark"));
            g_variant_builder_add(
                &props, "{sv}", "toggle-state",
                g_variant_new_int32(json_object_get_boolean_member(scope, "pinned")));
            break;
        }
        if (id >= 300 && id < 400 && menu_scope(id - 300)) {
            JsonObject *scope = menu_scope(id - 300);
            label = json_object_get_string_member(scope, "label");
            enabled = json_object_get_boolean_member(scope, "learned");
            break;
        }
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
            int ids[] = {1, 6, 2, 7, 8, 3, 4, 9, 10, 11, 5};
            for (size_t i = 0; i < G_N_ELEMENTS(ids); i++)
                g_variant_builder_add(&children, "v", menu_node(ids[i], next));
        }
        if (id == 10)
            for (int i = 0; i < 3; i++)
                g_variant_builder_add(&children, "v", menu_node(INDICATOR_OFF + i, next));
        if (id == 7 || id == 8)
            for (guint i = 0; i < scope_count(); i++)
                g_variant_builder_add(&children, "v",
                                      menu_node((id == 7 ? 200 : 300) + (int)i, next));
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
    if (id == 9)
        emit("clear-pins", "", "");
    if (id >= INDICATOR_OFF && id < INDICATOR_OFF + 3)
        emit("indicator", indicator_choices[id - INDICATOR_OFF][1], "");
    if (id == 11)
        emit("login-toggle", "", "");
    if ((id >= 200 && id < 300 && menu_scope(id - 200)) ||
        (id >= 300 && id < 400 && menu_scope(id - 300))) {
        JsonObject *scope = menu_scope(id % 100);
        char *scope_id = g_strdup(json_object_get_string_member(scope, "id"));
        emit(id < 300 ? "pin" : "forget", scope_id, "");
        g_free(scope_id);
    }
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

/* Mirrors the macOS template icon; symbolic names follow the panel's colour.
 * The names match tray_svg::name: insomemo[-dark][-<corner>]-symbolic. */
static const char *icon_name(void) {
    static char name[64];
    if (tray_paused)
        return "media-playback-pause-symbolic";
    if (!icon_theme_path)
        return "input-keyboard-symbolic";
    g_snprintf(name, sizeof name, "insomemo%s%s%s-symbolic", dark_ink ? "-dark" : "",
               badge_timer ? "-" : "", badge_timer ? indicator_position() : "");
    return name;
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
        return g_variant_new_string("insomemo");
    if (!strcmp(name, "Title"))
        return g_variant_new_string(tray_paused ? "Insomemo (Paused)" : "Insomemo");
    if (!strcmp(name, "XAyatanaLabel") || !strcmp(name, "XAyatanaLabelGuide"))
        return g_variant_new_string("");
    if (!strcmp(name, "Status"))
        return g_variant_new_string("Active");
    if (!strcmp(name, "IconThemePath"))
        return g_variant_new_string(icon_theme_path ? icon_theme_path : "");
    if (!strcmp(name, "WindowId"))
        return g_variant_new_int32(0);
    if (!strcmp(name, "IconName"))
        return g_variant_new_string(icon_name());
    if (g_str_has_suffix(name, "Pixmap"))
        return empty_pixmap();
    if (!strcmp(name, "ToolTip"))
        return g_variant_new("(s@a(iiay)ss)", icon_name(), empty_pixmap(),
                             tray_paused ? "Insomemo (Paused)" : "Insomemo",
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
    fprintf(stderr,
            "insomemo: no StatusNotifier tray host; daemon remains active (SIGTERM to quit)\n");
}

static void item_signal(const char *name) {
    if (bus)
        g_dbus_connection_emit_signal(bus, NULL, "/StatusNotifierItem",
                                      "org.kde.StatusNotifierItem", name, NULL, NULL);
}

void native_update(const char *context, int paused, const char *error, const char *layouts_json,
                   const char *menu_json) {
    gboolean context_changed = g_strcmp0(tray_context, context) != 0;
    gboolean paused_changed = tray_paused != paused;
    gboolean changed = context_changed || paused_changed || g_strcmp0(tray_error, error) ||
                       g_strcmp0(last_layouts, layouts_json) || g_strcmp0(last_menu, menu_json);
    if (!changed)
        return;
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
    if (g_strcmp0(last_menu, menu_json)) {
        JsonParser *parser = json_parser_new();
        if (json_parser_load_from_data(parser, menu_json, -1, NULL)) {
            if (tray_menu)
                json_object_unref(tray_menu);
            tray_menu = json_object_ref(json_node_get_object(json_parser_get_root(parser)));
        }
        g_object_unref(parser);
        g_free(last_menu);
        last_menu = g_strdup(menu_json);
    }
    revision++;
    if (!bus)
        return;
    // Signal only what changed: focus and title changes are frequent, and each
    // NewIcon makes the tray host fetch and redraw the icon.
    if (paused_changed) {
        item_signal("NewTitle");
        item_signal("NewIcon");
    }
    if (context_changed || paused_changed)
        item_signal("NewToolTip");
    // The menu shows the context, pause state, error, layouts, and scopes.
    g_dbus_connection_emit_signal(bus, NULL, "/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated",
                                  g_variant_new("(ui)", revision, 0), NULL);
}

void native_set_icon_theme(const char *path) {
    g_free(icon_theme_path);
    icon_theme_path = g_strdup(path);
}
void native_set_icon_ink(int dark) {
    if (dark_ink == !!dark)
        return;
    dark_ink = !!dark;
    item_signal("NewIcon");
}

/* Hosts that draw the icon file as is need an ink that suits the panel; Rust
 * decides from Cinnamon's theme or the desktop's light/dark preference. */
static void report_appearance(void) {
    char scheme[12];
    g_snprintf(scheme, sizeof scheme, "%u", color_scheme);
    emit("appearance", cinnamon_theme ? cinnamon_theme : "-", scheme);
}
static void cinnamon_theme_changed(GSettings *settings, const gchar *key, gpointer data) {
    (void)key;
    (void)data;
    g_free(cinnamon_theme);
    cinnamon_theme = g_settings_get_string(settings, "name");
    report_appearance();
}
static void set_color_scheme(GVariant *value) {
    // ReadOne returns the value in a variant; the older Read nests one more.
    GVariant *inner = g_variant_ref(value);
    while (g_variant_is_of_type(inner, G_VARIANT_TYPE_VARIANT)) {
        GVariant *next = g_variant_get_variant(inner);
        g_variant_unref(inner);
        inner = next;
    }
    guint32 scheme =
        g_variant_is_of_type(inner, G_VARIANT_TYPE_UINT32) ? g_variant_get_uint32(inner) : 0;
    g_variant_unref(inner);
    if (scheme == color_scheme)
        return;
    color_scheme = scheme;
    report_appearance();
}
static void read_color_scheme(const char *method);
static void color_scheme_read(GObject *source, GAsyncResult *result, gpointer data) {
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    if (!reply) {
        // Portals older than version 2 only offer Read. Without a portal, the
        // default (no preference) stands.
        if (!strcmp(data, "ReadOne") &&
            g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD))
            read_color_scheme("Read");
        g_error_free(error);
        return;
    }
    GVariant *value = g_variant_get_child_value(reply, 0);
    set_color_scheme(value);
    g_variant_unref(value);
    g_variant_unref(reply);
}
static void read_color_scheme(const char *method) {
    g_dbus_connection_call(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                           "org.freedesktop.portal.Settings", method,
                           g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"),
                           G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL,
                           color_scheme_read, (gpointer)method);
}
static void setting_changed(GDBusConnection *connection, const gchar *sender, const gchar *path,
                            const gchar *interface, const gchar *signal, GVariant *parameters,
                            gpointer data) {
    (void)connection;
    (void)sender;
    (void)path;
    (void)interface;
    (void)signal;
    (void)data;
    if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(ssv)")))
        return;
    const char *group, *key;
    GVariant *value;
    g_variant_get(parameters, "(&s&sv)", &group, &key, &value);
    if (!strcmp(group, "org.freedesktop.appearance") && !strcmp(key, "color-scheme"))
        set_color_scheme(value);
    g_variant_unref(value);
}
static void watch_appearance(void) {
    // Theme icons are the host's own; only Insomemo's icons have an ink.
    if (!icon_theme_path)
        return;
    const char *desktop = g_getenv("XDG_CURRENT_DESKTOP");
    GSettingsSchemaSource *source = g_settings_schema_source_get_default();
    GSettingsSchema *schema =
        desktop && strstr(desktop, "Cinnamon") && source
            ? g_settings_schema_source_lookup(source, "org.cinnamon.theme", TRUE)
            : NULL;
    if (schema) {
        if (g_settings_schema_has_key(schema, "name")) {
            GSettings *settings = g_settings_new_full(schema, NULL, NULL);
            // The settings object lives as long as the process, for its signal.
            g_signal_connect(settings, "changed::name", G_CALLBACK(cinnamon_theme_changed), NULL);
            cinnamon_theme = g_settings_get_string(settings, "name");
        }
        g_settings_schema_unref(schema);
    }
    if (bus) {
        g_dbus_connection_signal_subscribe(bus, "org.freedesktop.portal.Desktop",
                                           "org.freedesktop.portal.Settings", "SettingChanged",
                                           "/org/freedesktop/portal/desktop", NULL,
                                           G_DBUS_SIGNAL_FLAGS_NONE, setting_changed, NULL, NULL);
        read_color_scheme("ReadOne");
    }
    report_appearance();
}

static gboolean badge_done(gpointer data) {
    (void)data;
    badge_timer = 0;
    item_signal("NewIcon");
    return G_SOURCE_REMOVE;
}
/* Swaps in the badged icon, like macOS; without Insomemo's icons there is
 * nothing to badge. */
void native_indicate_switch(void) {
    if (!icon_theme_path)
        return;
    gboolean showing = badge_timer != 0;
    if (showing)
        g_source_remove(badge_timer);
    badge_timer = g_timeout_add(1200, badge_done, NULL);
    if (!showing)
        item_signal("NewIcon");
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
    watch_appearance();
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
