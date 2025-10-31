import os
import sys
import random
import string
import requests
import yaml

from .http_status_name import http_status_name
from .logger import setup_logger

logger = setup_logger()

def find_config_file():
    home = os.path.expanduser('~')
    candidates = [
        os.path.join(os.environ.get('XDG_CONFIG_HOME', os.path.join(home, '.config')), 'cloudtruth', 'cli.yml'),
        os.path.join(home, '.config', 'cloudtruth', 'cli.yml'),
        os.path.join(home, 'Library', 'Application Support', 'com.cloudtruth.CloudTruth-CLI', 'cli.yml'),
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
    return None

def load_api_config(profile):
    config_file = find_config_file()
    if not config_file:
        logger.error("🚨 Error: Could not find CloudTruth CLI config file.")
        sys.exit(1)
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
    profiles = config.get('profiles', {})
    p = profiles.get(profile, {})
    api_key = p.get('api_key')
    base_url = p.get('server_url')
    # Handle source_profile fallback
    if (not api_key or api_key == "null" or not base_url or base_url == "null") and 'source_profile' in p:
        sp = profiles.get(p['source_profile'], {})
        api_key = api_key or sp.get('api_key')
        base_url = base_url or sp.get('server_url')
    if not api_key or api_key == "null":
        logger.error("🚨 Error: API key is missing.")
        sys.exit(1)
    if not base_url or base_url == "null":
        base_url = "https://api.cloudtruth.io"
    return api_key, base_url.rstrip('/') + '/api/v1'

def api_request(method, url, api_key, payload=None):
    headers = {
        "Authorization": f"Api-Key {api_key}",
        "Content-Type": "application/json"
    }
    resp = requests.request(method, url, headers=headers, json=payload)
    try:
        resp.raise_for_status()
    except requests.HTTPError as e:
        logger.error(f"HTTP error for {method} {url}: {e}")
        logger.error(f"Response: {resp.text}")
        raise
    return resp

def get_id_by_name(url, api_key, name):
    resp = api_request("GET", url, api_key)
    results = resp.json().get('results', [])
    for item in results:
        if item.get('name') == name:
            return item.get('id')
    return None

def get_template_body(url, api_key):
    resp = api_request("GET", url, api_key)
    return resp.json().get('body')

def random_body():
    return "body-" + ''.join(random.choices(string.ascii_lowercase + string.digits, k=8))

def ensure_template_exists(base_url, api_key, project_id, template_name):
    templates_url = f"{base_url}/projects/{project_id}/templates/"
    template_id = get_id_by_name(templates_url, api_key, template_name)
    if not template_id:
        logger.info(f"ℹ️  Template '{template_name}' not found in project. Creating a new blank template...")
        payload = {"name": template_name, "body": "initial body"}
        resp = api_request("POST", templates_url, api_key, payload)
        logger.info(f"✅ Template '{template_name}' created.")
        template_id = get_id_by_name(templates_url, api_key, template_name)
        if not template_id:
            logger.error("🚨 Error: Could not confirm template creation.")
            raise RuntimeError("Could not confirm template creation.")
    else:
        logger.info(f"✅ Template '{template_name}' exists in project.")
    return template_id

def ensure_project_exists(base_url, api_key, project_name):
    projects_url = f"{base_url}/projects/"
    project_id = get_id_by_name(projects_url, api_key, project_name)
    if not project_id:
        logger.error(f"🚨 Error: Project '{project_name}' not found.")
        raise RuntimeError(f"Project '{project_name}' not found.")
    return project_id
