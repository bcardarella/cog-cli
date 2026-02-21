from intervals import Interval
from scheduler import find_max_concurrent


def main():
    """Schedule meetings and report the minimum number of rooms needed.

    The meeting data is arranged in two back-to-back blocks that share
    an exact boundary point (10:00).  Meetings within each block run
    concurrently, but the two blocks are merely *adjacent* -- they do
    NOT overlap.

    """

    meetings = [
        # --- Morning block: two parallel meetings, 9:00 - 10:00 ---
        Interval(9.0, 10.0),    # Engineering standup
        Interval(9.0, 10.0),    # Client sync

        # --- Mid-morning block: two parallel meetings, 10:00 - 11:00 ---
        Interval(10.0, 11.0),   # Design review
        Interval(10.0, 11.0),   # Sprint planning
    ]

    rooms = find_max_concurrent(meetings)
    print(f"Rooms needed: {rooms}")


if __name__ == "__main__":
    main()
