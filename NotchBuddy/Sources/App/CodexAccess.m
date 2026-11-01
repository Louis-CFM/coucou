#include "CodexAccess.h"
#include <limits.h>
#include <stdlib.h>

// Per-application ACLs for the file-based login Keychain have no modern replacement.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus CoucouCreateCodexAccess(CFStringRef executablePath, SecAccessRef *access) {
    if (!access) return errSecParam;
    *access = NULL;
    char path[PATH_MAX], resolved[PATH_MAX];
    if (!executablePath || !CFStringGetFileSystemRepresentation(executablePath, path, sizeof(path)) || !realpath(path, resolved)) {
        return errSecParam;
    }
    SecTrustedApplicationRef current = NULL, native = NULL;
    CFArrayRef trusted = NULL;
    OSStatus result = SecTrustedApplicationCreateFromPath(NULL, &current);
    if (result != errSecSuccess) goto cleanup;
    result = SecTrustedApplicationCreateFromPath(resolved, &native);
    if (result != errSecSuccess) goto cleanup;
    const void *applications[] = { current, native };
    trusted = CFArrayCreate(kCFAllocatorDefault, applications, 2, &kCFTypeArrayCallBacks);
    if (!trusted) { result = errSecAllocate; goto cleanup; }
    result = SecAccessCreate(CFSTR("Coucou temporary Codex access"), trusted, access);
cleanup:
    if (trusted) CFRelease(trusted);
    if (native) CFRelease(native);
    if (current) CFRelease(current);
    return result;
}
#pragma clang diagnostic pop
