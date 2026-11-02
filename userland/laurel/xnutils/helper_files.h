/* helper_files.c's writers, for helper_ios26.c */
#ifndef XT_HELPER_FILES_H
#define XT_HELPER_FILES_H
#include <sys/types.h>
int ensure_dir(const char *dir, mode_t mode);
int write_file(const char *path, const char *text);
int remove_file(const char *path);
#include <stdio.h>
FILE *open_planted(const char *path);
#endif
