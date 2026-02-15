// Segfault test fixture — dereferences null for exception testing.
// Compile: cc -c -g -O0 -o test/fixtures/segfault.o test/fixtures/segfault.c

#include <stddef.h>

int main(void) {
    int *p = NULL;
    return *p;
}
