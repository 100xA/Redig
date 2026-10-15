// Inspect CPU backend compatibility without initializing any GPU registry.
#ifndef DIGUP_CPU_LOADER_H
#define DIGUP_CPU_LOADER_H
#include <stdint.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif
static inline int32_t digup_cpu_backend_score(const char *path) {
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (!length) return -1;
    wchar_t *wide = (wchar_t *)malloc((size_t)length * sizeof(wchar_t));
    if (!wide) return -1;
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, length);
    HMODULE handle = LoadLibraryW(wide);
    free(wide);
    if (!handle) return -1;
    int (*score)(void) = (int (*)(void))GetProcAddress(handle, "ggml_backend_score");
    int32_t result = score ? score() : 0;
    FreeLibrary(handle);
#else
    void *handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return -1;
    int (*score)(void) = (int (*)(void))dlsym(handle, "ggml_backend_score");
    int32_t result = score ? score() : 0;
    dlclose(handle);
#endif
    return result;
}
#endif
