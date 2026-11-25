#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char** argv) {
    if (argc != 2 || (strcmp(argv[1], "read") != 0 && strcmp(argv[1], "denied") != 0)) {
        return 2;
    }
    const int fd = open("/dev/fprime/gate", O_RDONLY);
    if (fd == -1) {
        const int error = errno;
        if (strcmp(argv[1], "denied") == 0 && (error == EACCES || error == EPERM)) {
            printf("Gate open denied by permissions for uid=%lu\n", (unsigned long)getuid());
            return 0;
        }
        fprintf(stderr, "Gate open for uid=%lu: %s\n", (unsigned long)getuid(), strerror(error));
        return 1;
    }
    char data[256];
    const ssize_t count = read(fd, data, sizeof(data));
    const int close_status = close(fd);
    if (strcmp(argv[1], "read") != 0 || count <= 0 || close_status != 0 ||
        fwrite(data, 1, (size_t)count, stdout) != (size_t)count) {
        fputs("unexpected Gate open or read result\n", stderr);
        return 1;
    }
    return 0;
}
