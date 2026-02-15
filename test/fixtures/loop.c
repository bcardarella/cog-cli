// Loop test fixture — for loop that increments a counter.
// Compile: cc -c -g -O0 -o test/fixtures/loop.o test/fixtures/loop.c

int main(void) {
    int counter = 0;
    for (int i = 0; i < 10; i++) {
        counter += i;
    }
    return counter - 45;
}
