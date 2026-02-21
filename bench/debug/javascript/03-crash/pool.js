const { Resource } = require('./resource');
const { WaitQueue } = require('./queue');

class ResourcePool {
  constructor(size, options = {}) {
    this.size = size;
    this.available = [];
    this.inUse = [];
    this.waitQueue = new WaitQueue();
    this.onError = options.onError || null;

    // Create initial resources
    for (let i = 0; i < size; i++) {
      this.available.push(new Resource());
    }
  }

  async checkout() {
    if (this.available.length > 0) {
      const resource = this.available.pop();
      this.inUse.push(resource);
      return resource;
    }

    // Wait for a resource to become available
    const resource = await this.waitQueue.enqueue();
    return resource;
  }

  release(resource) {
    const idx = this.inUse.indexOf(resource);
    this.inUse.splice(idx, 1);

    // Give to waiting request or return to available pool
    const waiter = this.waitQueue.dequeue();
    if (waiter) {
      this.inUse.push(resource);
      waiter(resource);
    } else {
      this.available.push(resource);
    }
  }

  async execute(operation) {
    const resource = await this.checkout();
    try {
      const result = await resource.execute(operation);
      this.release(resource);
      return result;
    } catch (err) {
      // If an onError callback is registered, it may also call release().
      if (this.onError) {
        this.onError(err, resource, this);
      }
      this.release(resource);
      throw err;
    }
  }

  get stats() {
    return {
      total: this.size,
      available: this.available.length,
      inUse: this.inUse.length,
      waiting: this.waitQueue.length,
    };
  }
}

module.exports = { ResourcePool };
