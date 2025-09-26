import sys
import argparse
from cloudtruth_testing.logger import setup_logger
from cloudtruth_testing import test_trailing_slash_updates

logger = setup_logger(log_file="test_results.log", console_level="INFO", file_level="DEBUG")

# Collect test modules in a dictionary for easy extension
TESTS = {
    "trailing_slash_updates": test_trailing_slash_updates.main,
}

def main():
    parser = argparse.ArgumentParser(
        description="CloudTruth API Test Suite Runner"
    )
    parser.add_argument(
        'test_or_project',
        nargs='?',
        help="Test name (or project name if running all tests)"
    )
    parser.add_argument(
        'project',
        nargs='?',
        help="Project name"
    )
    args, remaining = parser.parse_known_args()

    # If the first argument matches a test name, treat it as test
    if args.test_or_project in TESTS or args.test_or_project == 'all':
        test_name = args.test_or_project
        project_arg = args.project
    else:
        # Otherwise, treat it as project and run all tests
        test_name = 'all'
        project_arg = args.test_or_project

    # Build remaining args for test modules
    test_args = []
    if project_arg:
        test_args.append(project_arg)
    test_args.extend(remaining)

    exit_code = 0
    results = {}

    if test_name == 'all':
        test_list = list(TESTS.keys())
        logger.info("=== Running all tests: ===")
        for name in test_list:
            logger.info(f"  - {name}")
        for name in test_list:
            logger.info(f"--- Running: {name.replace('_', ' ').title()} ---")
            result = TESTS[name](test_args)
            passed = (result == 0 or result is None)
            results[name] = passed
            if not passed:
                exit_code = result if result else 1
        logger.info(f"=== Completed all tests: {', '.join(test_list)} ===")
        # Summary
        for name in test_list:
            status = "PASS" if results[name] else "FAIL"
            logger.info(f"Test: {name.replace('_', ' ').title()} - {status}")
    else:
        logger.info(f"=== Running test: {test_name.replace('_', ' ').title()} ===")
        result = TESTS[test_name](test_args)
        passed = (result == 0 or result is None)
        results[test_name] = passed
        logger.info(f"=== Completed test: {test_name.replace('_', ' ').title()} ===")
        status = "PASS" if passed else "FAIL"
        logger.info(f"Test: {test_name.replace('_', ' ').title()} - {status}")
        exit_code = result if result else 0

    sys.exit(exit_code)

if __name__ == "__main__":
    main()
