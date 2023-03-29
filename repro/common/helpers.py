from http.client import NOT_IMPLEMENTED
import os
import platform
import requests
from requests.exceptions import HTTPError
import yaml
from rich.console import Console

API_TIMEOUT = 300
console = Console()

def get_profile_url(profile):
    return get_profile_data(profile)['server_url']

def get_profile_api_key(profile):
    return get_profile_data(profile)['api_key']

def get_profile_data(profile):
    cli_config_filename = 'cli.yml'
    path = ''

    match platform.system().lower():
        case 'darwin':
            home_dir = os.environ.get('HOME')
            path = (
                f'{home_dir}/Library/Application Support/com.cloudtruth.CloudTruth-CLI/' +
                f'{cli_config_filename}'
            )
        case 'linux':
            home_dir = os.environ.get('XDG_CONFIG_HOME')
            path = f'{home_dir}/cloudtruth/{cli_config_filename}'
        case 'windows':
            app_data = os.environ.get('APPDATA')
            path = fr'{app_data}\CloudTruth\CloudTruth CLI\config\{cli_config_filename}'
        case _:
            exit('Cannot determine config file path, exiting.')

    with open(path, 'r', encoding='utf_8') as file:
        config = yaml.safe_load(file)

    if profile not in config['profiles']:
        exit('Profile not found, check spelling or create a new profile via the CloudTruth CLI')

    return config['profiles'][profile]

def make_request(uri, http_method, headers, body = None):
    try:
        response = requests.request(
            method=http_method.upper(),
            url=uri,
            headers=headers,
            timeout=API_TIMEOUT,
            json=body
        )

        response.raise_for_status()
    except HTTPError as err:
        console.log(err)
        console.log(locals()) #TODO: Debugging-only!!!
        exit()

    return response

def get_objects_list(cloudtruth_type, api_url, headers):
    url = f'{api_url}/{cloudtruth_type}/'
    return make_request(url, 'get', headers).json().get('results')

def get_object_by_name(name, cloudtruth_type, api_url, headers):
    objs = get_objects_list(cloudtruth_type, api_url, headers)

    for obj in objs:
        if obj['name'] == name:
            return obj

    return None

def delete_object(obj, cloudtruth_type, api_url, headers):
    obj_id = obj.get('id')
    url = f'{api_url}/{cloudtruth_type}/{obj_id}/'

    make_request(url, 'delete', headers)

def get_object_by_id(id, cloudtruth_type, api_url, headers):
    return NOT_IMPLEMENTED

#### PROJECTS

def create_project(name, api_url, headers, parent = None):
    project_url = f'{api_url}/projects/'
    depends_on = parent.get('url') if parent is not None else ''
    body = {
        "name": name,
        "depends_on": depends_on
    }

    project = make_request(project_url, 'post', headers, body).json()

    return project

def delete_project(project, api_url, headers, force = False):
    project_and_dependents = get_project_tree_projects(project, api_url, headers)

    for project in reversed(project_and_dependents):
        if force:
            delete_project_parameters(project, api_url, headers)
        console.log(f"Deleting project: {project.get('name')}")
        delete_object(project, 'projects', api_url, headers)

def project_has_dependents(project):
    child_project_urls = project.get('dependents')
    if len(child_project_urls) > 0:
        return True

    return False

def project_has_parent(project):
    parent_project_url = project.get('depends_on')
    if parent_project_url:
        return True

    return False

def get_project_tree_projects(project, api_url, headers, projects = None):
    if project is None:
        return None
    if projects is None:
        projects = []
        console.log(f"Adding parent, {project.get('name')} to the list")
        projects.append(project) # put the parent in the list on init
    if project_has_dependents(project):
        child_project_urls = project.get('dependents')
        for child_project_url in child_project_urls:
            child_project = make_request(child_project_url, 'get', headers).json()
            if project_has_dependents(child_project): # if the child has dependents
                console.log(f"Adding a child to the list, {child_project.get('name')} with dependencies")
                projects.append(child_project)
                get_project_tree_projects(child_project, api_url, headers, projects)
            else:
                console.log(f"Adding a child to the list, {child_project.get('name')} with no dependencies")
                projects.append(child_project)

    return projects

def get_all_top_level_projects(api_url, headers):
    all_projects = get_objects_list('projects', api_url, headers)
    top_level_projects = []

    for project in all_projects:
        if project_has_parent(project) is False:
            top_level_projects.append(project)

    return top_level_projects

#### PARAMETERS

def create_parameter(name, project, api_url, headers):
    #TODO: handle secrets?

    project_id = project.get('id')
    param_url = f"{api_url}/projects/{project_id}/parameters/"
    body = {
        "name": name
    }

    param = make_request(param_url, 'post', headers, body).json()

    return param

def delete_project_parameters(project, api_url, headers):
    project_id = project.get('id')
    project_parameters_url = f"{api_url}/projects/{project_id}/parameters/"
    parameters = make_request(project_parameters_url, 'get', headers).json().get('results', [])

    console.print(f"Deleting {parameters.count()} parameters from project {project.get('name')}")
    for parameter in parameters:
        delete_parameter(project_id, parameter, api_url, headers)

def delete_parameter(project_id, parameter, api_url, headers):
    parameter_id = parameter.get('id')
    parameter_url = f"{api_url}/projects/{project_id}/parameters/{parameter_id}"

    make_request(parameter_url, 'delete', api_url, headers)

#### ENVIRONMENTS

def create_environment(name, api_url, headers, parent = None):
    env_url = f'{api_url}/environments/'
    parent_uri = parent.get('url') if parent is not None else ''
    body = {
        "name": name,
        "parent": parent_uri
    }

    env = make_request(env_url, 'post', headers, body).json()

    return env

#### MISC

def nuke():
    return NOT_IMPLEMENTED
