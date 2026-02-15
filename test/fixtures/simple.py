# Simple Python fixture for DAP proxy end-to-end testing.
# Used with debugpy to test breakpoint, step, and inspect operations.

def add(a, b):
    result = a + b
    return result

def main():
    x = 42
    y = add(x, 1)
    print(f"Result: {y}")
    return y

if __name__ == "__main__":
    main()
