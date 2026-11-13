#ifndef COUCOU_CODEX_ACCESS_H
#define COUCOU_CODEX_ACCESS_H

#include <Security/Security.h>

OSStatus CoucouCreateCodexAccess(CFStringRef _Nonnull executablePath,
                                SecAccessRef _Nullable * _Nonnull CF_RETURNS_RETAINED access);

#endif
