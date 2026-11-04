#define _GNU_SOURCE
#include <dlfcn.h>
#include <gtk/gtk.h>

// Reproduce a lost WebKitGTK leave event without faking the pointer position
// read by the native watcher. This library is preloaded only in the test.
void gtk_main_do_event(GdkEvent *event) {
    static void (*real_event)(GdkEvent *) = NULL;
    if (!real_event) real_event = dlsym(RTLD_NEXT, "gtk_main_do_event");
    if (event->type == GDK_LEAVE_NOTIFY) return;
    real_event(event);
}
