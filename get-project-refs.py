import os
import sys
import argparse
import requests
import json
import http

# debug
# import pdb


def parse_args():
    usage_text = 'Uses the CloudTruth CLI to iterate through all projects \
                to find and list any parameters matching the given \
                search string.'
    parser = argparse.ArgumentParser(description=usage_text)
    parser.add_argument(
        '-s', '--stage', help='The release stage to use, i.e. `staging`')
    parser.add_argument(
        '-m', '--match', help='The string to match against', required=True)

    return parser.parse_args()

def extract_values(obj, key, project_name):
    arr = []
    environment = ''

    def extract(obj, arr, key):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(v, (dict, list)):
                    extract(v, arr, key)
                elif k == 'environment_name': #TODO: DUMMY, ORDER MATTERS!
                    environment = v
                elif k == key:
                    if v is not None:
                        arr.append(f'{project_name}, {environment}, {v}')
        elif isinstance(obj, list):
            for item in obj:
                extract(item, arr, key)
        return arr

    values = extract(obj, arr, key)
    return values


def main(argv):
    api_url = 'https://api.cloudtruth.io/api/v1'
    api_key = os.environ.get('CLOUDTRUTH_API_KEY')
    headers = {'Authorization': f'Api-Key {api_key}'}

    args = parse_args()
    matcher = args.match

    if args.stage is not None:
        api_url = f'https://api.{args.stage}.cloudtruth.io/api/v1'

    data = {}
    if api_key is not None:
        proj_response = requests.get(f'{api_url}/projects', headers=headers)
        if proj_response.status_code == http.HTTPStatus.OK:
            projects = proj_response.json()['results']
            if len(projects) > 0:
                for project in projects:

                    if project['name'] == matcher:
                        continue

                    proj_param_response = requests.get(
                        f'{api_url}/projects/{project["id"]}/parameters', headers=headers)
                    if proj_param_response.status_code == http.HTTPStatus.OK:
                        values = extract_values(proj_param_response.json(), 'internal_value', project['name'])
                        for value in values:
                            if matcher in value:
                                print(f'matched value: {value}')



if __name__ == "__main__":
    main(sys.argv[1:])
