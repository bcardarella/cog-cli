// Simple Node.js fixture for CDP end-to-end testing.
// Used with node --inspect to test breakpoint, step, and inspect operations.

function add(a, b) {
    const result = a + b;
    return result;
}

function main() {
    const x = 42;
    const y = add(x, 1);
    console.log(`Result: ${y}`);
    return y;
}

main();
