// Minimal test fixture for DWARF debug info testing.
// Compile: cc -c -g -O0 -o test/fixtures/simple.o test/fixtures/simple.c

int add(int a, int b) {
    return a + b;
}

int main(void) {
    int x = 42;
    int y = add(x, 1);
    return y - 43;
}
