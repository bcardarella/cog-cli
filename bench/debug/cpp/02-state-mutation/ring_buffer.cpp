#include "ring_buffer.h"

RingBuffer::RingBuffer(size_t cap)
    : capacity(cap), head(0), tail(0), count(0) {
    buffer = new Message[capacity];
}

RingBuffer::~RingBuffer() {
    delete[] buffer;
}

bool RingBuffer::push(const Message& msg) {
    if (isFull()) {
        return false;
    }

    buffer[tail] = msg;
    tail = (tail + 1) % capacity;
    count++;
    return true;
}

bool RingBuffer::pop(Message& msg) {
    if (isEmpty()) {
        return false;
    }

    msg = buffer[head];
    head = (head + 1) % (capacity + 1);
    count--;
    return true;
}

bool RingBuffer::isEmpty() const {
    return count == 0;
}

bool RingBuffer::isFull() const {
    return count == capacity;
}

size_t RingBuffer::size() const {
    return count;
}
