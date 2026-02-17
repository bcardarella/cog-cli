#include <stdio.h>
#include <unistd.h>

int counter = 0;               // line 4

void tick() {
    counter++;                 // line 7
    printf("tick %d\n", counter); // line 8
}

int main() {
    printf("pid: %d\n", getpid()); // line 12
    fflush(stdout);                 // line 13
    for (int i = 0; i < 300; i++) { // line 14
        tick();                     // line 15
        sleep(1);                   // line 16
    }
    return 0;                       // line 18
}
