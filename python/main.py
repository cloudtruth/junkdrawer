import sys
import argparse
from cloudtruth_testing import test_trailing_slash_updates

# Collect test modules in a dictionary for easy extension
TESTS = {
    "trailing_slash_updates": test_trailing_slash_updates.main,
}

def main():
    parser = argparse.ArgumentParser(
        description="CloudTruth API Test Suite Runner"
    )
    parser.add_argument(
        'test',
        nargs='?',
        choices=list(TESTS.keys()) + ['all'],
        default='all',
        help="Which test to run (default: all)"
    )
    # Parse known args so we can forward the rest to the test
    args, remaining = parser.parse_known_args()

    exit_code = 0

    if args.test == 'all':
        for name, test_func in TESTS.items():
            print(f"=== Running: {name.replace('_', ' ').title()} ===")
            result = test_func(remaining)
            if result:
                exit_code = result  # capture non-zero exit codes
    else:
        print(f"=== Running: {args.test.replace('_', ' ').title()} ===")
        exit_code = TESTS[args.test](remaining)

    sys.exit(exit_code)

if __name__ == "__main__":
    main()
