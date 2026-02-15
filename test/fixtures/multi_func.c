// Multi-function test fixture for stack trace testing.
// Compile: cc -c -g -O0 -o test/fixtures/multi_func.o test/fixtures/multi_func.c

int helper(int n) {
    return n * 2;
}

int compute(int x) {
    int result = helper(x);
    return result + 1;
}

int main(void) {
    return compute(21) - 43;
}
