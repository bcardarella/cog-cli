from loader import load_config
from validator import validate_config


def main():
    """Load the production configuration and report the result."""
    config = load_config("production")
    settings_count = validate_config(config)
    print(f"Config loaded: {settings_count} settings applied")


if __name__ == "__main__":
    main()
