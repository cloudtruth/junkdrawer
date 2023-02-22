import os
import argparse
from argparse import RawTextHelpFormatter
import requests
from requests.exceptions import HTTPError
from tabulate import tabulate

# debug
# import pdb

API_KEY = os.environ.get('CLOUDTRUTH_API_KEY')
API_BASE_URL = 'https://api.cloudtruth.io/api/v1'
HEADERS = {'Authorization': f'Api-Key {API_KEY}'}
TIMEOUT = 300
INTEGRATION_SERVICES = ['azure', 'aws', 'github']
DENIED_ROLES = ['VIEWER', 'CONTRIB']

def parse_args():
    usage_text = (
        'Uses the CloudTruth API to delete all integrations.\n' +
        'Optional: type of integration and wether or not to remove any ' +
        'associate actions.\n' +
        'Requires CLOUDTRUTH_API_KEY env variable to be set'
    )
    parser = argparse.ArgumentParser(description=usage_text, formatter_class=RawTextHelpFormatter)
    parser.add_argument(
        '-s', '--service',
        metavar='',
        help=f"Specified integration service to remove, one of {INTEGRATION_SERVICES})"
    )
    parser.add_argument(
        '-r', '--release_stage',
        metavar='',
        help='The release stage to use, i.e. `staging`'
    )
    parser.add_argument(
        '-f', '--force',
        action='store_true',
        help='Removes integrations along with any associated actions'
    )
    parser.add_argument(
        '-d', '--dry-run',
        action='store_true',
        help='Lists what integrations would be removed'
    )

    return parser.parse_args()

def get_integration_pulls(integration_uuid, service, api_base_url):
    pulls_url = f'{api_base_url}/integrations/{service}/{integration_uuid}/pulls/'

    try:
        pulls = requests.get(pulls_url, headers=HEADERS, timeout=TIMEOUT)
        pulls.raise_for_status()
    except HTTPError as err:
        print(err)

    return pulls

def get_integration_pushes(integration_uuid, service, api_base_url):
    pushes_url = f'{api_base_url}/integrations/{service}/{integration_uuid}/pushes/'

    try:
        pushes = requests.get(pushes_url, headers=HEADERS, timeout=TIMEOUT)
        pushes.raise_for_status()
    except HTTPError as err:
        print(err)

    return pushes

def delete_integration_pull(pull):
    pull_url = pull['url']
    if pull['name'] == 'ExternalValues':
        return
    try:
        print(f"Attempting to delete pull: {pull['name']}")
        pull_delete_resp = requests.delete(pull_url, headers=HEADERS, timeout=TIMEOUT)
        pull_delete_resp.raise_for_status()
    except HTTPError as err:
        print(err)


def delete_integration_push(push):
    push_url = push['url']
    try:
        print(f"Attempting to delete push: {push['name']}")
        push_delete_resp = requests.delete(push_url, headers=HEADERS, timeout=TIMEOUT)
        push_delete_resp.raise_for_status()
    except HTTPError as err:
        print(err)

def main():
    args = parse_args()

    if API_KEY is None:
        exit('No api key set')

    api_base_url = API_BASE_URL

    if args.service and args.service not in INTEGRATION_SERVICES:
        exit(f'Service must be one of {INTEGRATION_SERVICES}')

    if args.release_stage:
        api_base_url = f'https://api.{args.release_stage}.cloudtruth.io/api/v1'

    try:
        user_current_info = requests.get(
            f'{api_base_url}/users/current',
            headers=HEADERS,
            timeout=TIMEOUT
        )
        user_current_info.raise_for_status()

        role = user_current_info.json().get('role').upper()
        if role in DENIED_ROLES:
            exit(f'Insufficient privileges for role: {role}')
    except HTTPError as err:
        raise SystemExit(err) from err

    integrations_url = f'{api_base_url}/integrations'
    integrations = []

    for integration_service in INTEGRATION_SERVICES:
        if args.service:
            if integration_service != args.service:
                continue

        if integration_service == 'azure':
            integration_service = 'azure/key_vault'

        try:
            integrations_response = requests.get(
                f'{integrations_url}/{integration_service}',
                headers=HEADERS,
                timeout=TIMEOUT
            )
            integrations_response.raise_for_status()

            for result in integrations_response.json().get("results", []):
                integrations.append([
                    result['id'],
                    result['name'],
                    result['url'],
                    integration_service
                ])
        except HTTPError as err:
            raise SystemExit(err) from err

    if len(integrations) == 0:
        exit('No integrations were found')

    if args.dry_run:
        headers=['uuid','name','url','service']
        print('[DRY RUN] The following integrations would be removed:\n')
        print(tabulate(integrations, headers=headers, tablefmt='orgtbl'))
        exit(f'\nNumber of integrations found: {len(integrations)}')

    for integration in integrations:
        integration_uuid = integration[0]
        integration_name = integration[1]
        integration_url = integration[2]
        integration_service = integration[3]

        pulls = get_integration_pulls(
            integration_uuid,
            integration_service,
            api_base_url
        ).json().get('results', [])

        pushes = get_integration_pushes(
            integration_uuid,
            integration_service,
            api_base_url
        ).json().get('results', [])

        if args.force is False:
            if len(pulls) > 0 or len(pushes) > 0:
                exit('Integration has pushes or pulls; use force (-f, --force) to remove everything')

        if len(pulls) > 0:
            for pull in pulls:
                delete_integration_pull(pull)
        if len(pushes) > 0:
            for push in pushes:
                delete_integration_push(push)

        try:
            print(f'Deleting integration: {integration_name}')
            delete_result = requests.delete(integration_url, headers=HEADERS, timeout=TIMEOUT)
            delete_result.raise_for_status()
        except HTTPError as err:
            raise SystemExit(err) from err

if __name__ == "__main__":
    main()
