#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int join_path(char *destination, size_t capacity, const char *left, const char *right) {
    int written = snprintf(destination, capacity, "%s/%s", left, right);
    return written >= 0 && (size_t)written < capacity;
}

static int parent_directory(char *path) {
    char *separator = strrchr(path, '/');
    if (separator == NULL || separator == path) {
        return 0;
    }
    *separator = '\0';
    return 1;
}

int main(int argc, char *argv[]) {
    char executable_path[PATH_MAX];
    uint32_t executable_path_size = sizeof(executable_path);
    if (_NSGetExecutablePath(executable_path, &executable_path_size) != 0) {
        fputs("EasySplat COLMAP launcher could not resolve its executable path.\n", stderr);
        return 70;
    }

    char resolved_executable[PATH_MAX];
    if (realpath(executable_path, resolved_executable) == NULL || !parent_directory(resolved_executable)) {
        fputs("EasySplat COLMAP launcher could not resolve its runtime directory.\n", stderr);
        return 70;
    }

    char python_path[PATH_MAX];
    char app_path[PATH_MAX];
    if (!join_path(python_path, sizeof(python_path), resolved_executable, "../python/bin/python3") ||
        !join_path(app_path, sizeof(app_path), resolved_executable, "../app") ||
        access(python_path, X_OK) != 0) {
        if (!join_path(python_path, sizeof(python_path), resolved_executable, "../da3_mps/python/bin/python3") ||
            !join_path(app_path, sizeof(app_path), resolved_executable, "../da3_mps/app") ||
            access(python_path, X_OK) != 0) {
            fputs("EasySplat COLMAP launcher could not find its bundled Python runtime.\n", stderr);
            return 69;
        }
    }

    unsetenv("PYTHONHOME");
    unsetenv("PYTHONUSERBASE");
    unsetenv("PYTHONSTARTUP");
    unsetenv("PYTHONINSPECT");
    if (setenv("PYTHONNOUSERSITE", "1", 1) != 0 ||
        setenv("PYTHONSAFEPATH", "1", 1) != 0 ||
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1) != 0 ||
        setenv("PYTHONPATH", app_path, 1) != 0 ||
        setenv("KMP_DUPLICATE_LIB_OK", "TRUE", 0) != 0) {
        fputs("EasySplat COLMAP launcher could not configure its runtime.\n", stderr);
        return 70;
    }

    size_t argument_count = (size_t)argc + 3;
    char **python_arguments = calloc(argument_count, sizeof(char *));
    if (python_arguments == NULL) {
        fputs("EasySplat COLMAP launcher could not allocate its argument list.\n", stderr);
        return 71;
    }
    python_arguments[0] = python_path;
    python_arguments[1] = "-m";
    python_arguments[2] = "easysplat_da3_sfm.colmap_cli";
    for (int index = 1; index < argc; ++index) {
        python_arguments[index + 2] = argv[index];
    }
    python_arguments[argc + 2] = NULL;

    execv(python_path, python_arguments);
    perror("EasySplat COLMAP launcher could not start its bundled runtime");
    free(python_arguments);
    return 69;
}
