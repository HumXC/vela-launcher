#define _GNU_SOURCE 1
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdlib.h>
