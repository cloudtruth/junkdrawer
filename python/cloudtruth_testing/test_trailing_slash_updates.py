import sys
import argparse
from .base import (
    load_api_config,
    ensure_project_exists,
    ensure_template_exists,
    get_template_body,
    random_body,
    api_request,
)
from .http_status_name import http_status_name
from .logger import setup_logger
from urllib.parse import urlparse

logger = setup_logger(log_file="test_results.log", console_level="INFO", file_level="DEBUG")

def parse_args(args=None):
    parser = argparse.ArgumentParser(
        description="Test CloudTruth API template update behavior with and without trailing slashes using PATCH and PUT."
    )
    parser.add_argument('project', help='CloudTruth project name')
    parser.add_argument('--template', default='test-template', help='Template name (default: test-template)')
    parser.add_argument('--env', default=None, help='Environment (optional)')
    parser.add_argument('--profile', default='default', help='CloudTruth CLI profile (default: default)')
    parser.add_argument('-n', '--dry-run', action='store_true', help='Show actions without making changes')
    return parser.parse_args(args)

def get_endpoint_path(url):
    # Returns the path and query after /v1/
    parsed = urlparse(url)
    path = parsed.path
    v1_index = path.find('/v1/')
    if v1_index != -1:
        return path[v1_index + 4:] + (f"?{parsed.query}" if parsed.query else "")
    return path + (f"?{parsed.query}" if parsed.query else "")

def test_update(method, url, api_key, template_name, new_body, dry_run):
    payload = {"body": new_body}
    if method == "PUT":
        payload["name"] = template_name
        logger.info(f"PUT payload: {payload}")

    body_before = get_template_body(url, api_key)

    if dry_run:
        logger.info(f"DRY RUN: {method} {get_endpoint_path(url)} with payload: {payload}")
        logger.info(f"Body before: {body_before}")
        logger.info("Body after: (dry run, not updated)")
        return

    endpoint = get_endpoint_path(url)
    logger.info(f"Testing {method} {endpoint}")
    resp = api_request(method, url, api_key, payload)
    logger.debug(f"API Response [{method} {endpoint}]: {resp.status_code} {resp.text}")
    status = resp.status_code
    status_name = http_status_name(status)

    if 200 <= status < 300:
        logger.info(f"✅ {method} {endpoint} succeeded.")
    else:
        logger.error(f"❌ {method} {endpoint} failed. Status: {status} ({status_name})")
        logger.error(resp.text)

    body_after = get_template_body(url, api_key)
    logger.info(f"Body before: {body_before}")
    logger.info(f"Body after:  {body_after}")

    if body_after == new_body:
        logger.info("✅ Template body updated as expected.")
    else:
        logger.error("❌ Template body NOT updated as expected.")

def main(args=None):
    args = parse_args(args)
    api_key, base_url = load_api_config(args.profile)

    # Print base URL once
    base_url_prefix = base_url.rstrip('/')
    logger.info(f"Base URL: {base_url_prefix}")

    # Get Project ID
    project_id = ensure_project_exists(base_url, api_key, args.project)

    # Get/Create Template
    template_id = ensure_template_exists(base_url, api_key, project_id, args.template)

    template_url = f"{base_url}/projects/{project_id}/templates/{template_id}/"
    template_url_no_slash = template_url.rstrip('/')

    rand_body = random_body()

    logger.info("== PATCH without trailing slash ==")
    test_update("PATCH", template_url_no_slash, api_key, args.template, f"{rand_body}-patch-no-slash", args.dry_run)

    logger.info("== PATCH with trailing slash ==")
    test_update("PATCH", template_url, api_key, args.template, f"{rand_body}-patch-slash", args.dry_run)

    logger.info("== PUT without trailing slash ==")
    test_update("PUT", template_url_no_slash, api_key, args.template, f"{rand_body}-put-no-slash", args.dry_run)

    logger.info("== PUT with trailing slash ==")
    test_update("PUT", template_url, api_key, args.template, f"{rand_body}-put-slash", args.dry_run)

    logger.info("Done.")

if __name__ == "__main__":
    main()
