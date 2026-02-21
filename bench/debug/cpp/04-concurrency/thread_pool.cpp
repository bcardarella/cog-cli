#include "thread_pool.h"

ThreadPool::ThreadPool(size_t n)
    : running_(true), pendingTasks_(0), numThreads_(n) {
    for (size_t i = 0; i < n; i++) {
        queues_.push_back(std::make_unique<TaskQueue>());
    }
    for (size_t i = 0; i < n; i++) {
        threads_.emplace_back(&ThreadPool::workerLoop, this, i);
    }
}

ThreadPool::~ThreadPool() {
    running_ = false;
    for (auto& t : threads_) {
        if (t.joinable()) t.join();
    }
}

void ThreadPool::submit(TaskQueue::Task task) {
    static std::atomic<size_t> counter(0);
    size_t idx = counter++ % numThreads_;
    pendingTasks_++;
    queues_[idx]->push(std::move(task));
}

void ThreadPool::submitTo(size_t queueIdx, TaskQueue::Task task) {
    pendingTasks_++;
    queues_[queueIdx % numThreads_]->push(std::move(task));
}

void ThreadPool::waitAll() {
    while (pendingTasks_ > 0) {
        std::this_thread::yield();
    }
}

void ThreadPool::workerLoop(size_t id) {
    while (running_ || pendingTasks_ > 0) {
        TaskQueue::Task task;

        if (queues_[id]->pop(task)) {
            task();
            pendingTasks_--;
        } else if (trySteal(id, task)) {
            task();
            pendingTasks_--;
        } else {
            std::this_thread::yield();
        }
    }
}

bool ThreadPool::trySteal(size_t thiefId, TaskQueue::Task& task) {
    for (size_t i = 0; i < numThreads_; i++) {
        if (i == thiefId) continue;

        std::lock_guard<std::mutex> lock1(queues_[thiefId]->getMutex());
        std::lock_guard<std::mutex> lock2(queues_[i]->getMutex());

        if (queues_[i]->stealNoLock(task)) {
            return true;
        }
    }
    return false;
}
