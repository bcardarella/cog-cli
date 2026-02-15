// FFI boundary test fixture — simulates cross-language call boundary.
// Compile: cc -c -g -O0 -o test/fixtures/ffi_boundary.o test/fixtures/ffi_boundary.c

// Simulates a function that would cross into another language runtime
// (e.g., cgo crosscall2). In real usage, this would call into Go/Python/etc.
int crosscall2(int value) {
    return value * 3;
}

int native_func(int x) {
    return crosscall2(x) + 1;
}

int main(void) {
    return native_func(14) - 43;
}
