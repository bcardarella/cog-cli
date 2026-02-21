"""Recursive dictionary merger for layered configuration."""

import copy


def deep_merge(base, overlay):
    """Recursively merge *overlay* into *base* and return a new dict.

    Rules
    -----
    * If both ``base[key]`` and ``overlay[key]`` are dicts, merge
      recursively.
    * If ``overlay[key]`` is ``None``, special handling applies.
    * Otherwise, ``overlay[key]`` overwrites ``base[key]``.

    """
    result = copy.deepcopy(base)

    for key, value in overlay.items():
        if (
            key in result
            and isinstance(result[key], dict)
            and isinstance(value, dict)
        ):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value

    return result
