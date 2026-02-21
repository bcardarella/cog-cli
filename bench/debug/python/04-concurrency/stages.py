import time
from queue import Full


class Stage1:
    """Producer stage. Generates items and reads feedback from Stage 2."""

    def __init__(self, queue_mgr, num_items):
        self.queue_mgr = queue_mgr
        self.num_items = num_items
        self.feedback_count = 0

    def run(self):
        for i in range(self.num_items):
            item = {"id": i, "value": i * 10, "adjustments": []}

            # Check for feedback from Stage 2
            while not self.queue_mgr.feedback.empty():
                fb = self.queue_mgr.feedback.get()
                self.feedback_count += 1
                # Apply feedback adjustment to future items
                item["adjustments"].append(fb)

            self.queue_mgr.stage1_to_stage2.put(item)

        self.queue_mgr.done_producing = True
        # Send sentinel to signal Stage 2 to stop
        self.queue_mgr.stage1_to_stage2.put(None)


class Stage2:
    """Processing stage. Transforms items and sends feedback to Stage 1."""

    def __init__(self, queue_mgr):
        self.queue_mgr = queue_mgr
        self.processed = 0

    def run(self):
        while True:
            item = self.queue_mgr.stage1_to_stage2.get()
            if item is None:
                break

            # Process the item
            item["value"] = item["value"] * 2 + 1
            item["processed"] = True
            self.processed += 1

            # Send feedback to Stage 1 for every item
            feedback = {
                "from_item": item["id"],
                "suggestion": "increase_rate",
                "metric": self.processed,
            }
            self.queue_mgr.feedback.put(feedback)

            # Forward to Stage 3
            self.queue_mgr.stage2_to_stage3.put(item)

        self.queue_mgr.done_processing = True
        self.queue_mgr.stage2_to_stage3.put(None)


class Stage3:
    """Consumer stage. Collects processed items."""

    def __init__(self, queue_mgr):
        self.queue_mgr = queue_mgr
        self.results = []

    def run(self):
        while True:
            item = self.queue_mgr.stage2_to_stage3.get()
            if item is None:
                break
            self.results.append(item)
