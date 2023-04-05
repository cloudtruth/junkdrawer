#!/usr/bin/env python3

import argparse
from argparse import RawTextHelpFormatter
import shortuuid
from rich.console import Console
from common import helpers

console = Console()

PROJECT_PREFIX = 'proj-testing_'
ENVIRONMENT_PREFIX = 'env-testing_'
PARAMETER_PREFIX = 'param-testing_'

EXIT_ERR = 1
EXIT_SUCCESS = 0


def parse_args():
    usage_text = (
        'Creates or deletes projects, envs, templates, and parameters based on inputs'
    )
    parser = argparse.ArgumentParser(description=usage_text, formatter_class=RawTextHelpFormatter)
    parser.add_argument(
        '--profile',
        help='The CloudTruth CLI profile to use',
        required=True,
    )
    parser.add_argument(
        '--projects',
        help='base type, project create or delete',
        action='store_true',
    )
    parser.add_argument(
        '--environments',
        help='base type, environment create or delete',
        action='store_true',
    )
    parser.add_argument(
        '--templates',
        help='base type, template create or delete',
        action='store_true',
    )
    parser.add_argument(
        '--project-root-name',
        nargs='?',
        metavar='<string>',
        help='set a root project for the new projects',
    )
    parser.add_argument(
        '--environment-root-name',
        nargs='?',
        metavar='<string>',
        help='set a root environment for the new environments',
    )
    parser.add_argument(
        '--levels',
        metavar='N',
        help=(
                'Number of extra levels to nest (depth).\n' +
                'each level will get the same number of child projects and environments, default is 0'
        ),
        type=int,
        default=0,
    )
    parser.add_argument(
        '--create',
        help='Create given types if empty and not associated, requires one or more base types to be set',
        action='store_true',
    )
    parser.add_argument(
        '--delete',
        help='Delete given types if empty and not associated, requires one or more base types to be set',
        action='store_true',
    )
    parser.add_argument(
        '--keep',
        help='Will keep the created items and not clean up',
        action='store_true',
    )
    parser.add_argument(
        '--force',
        help=(
                'Used for deleting everything associated with the given type, ' +
                'requires a base type to be set'
        ),
        action='store_true',
    )
    parser.add_argument(
        '--reset-org',
        help=(
                'The nuclear option. Resets org to default state. ' +
                'Will delete everything, even previously created models'
        ),
        action='store_true',
    )
    parser.add_argument(
        '--project-count',
        metavar='',
        help='Number of projects to create, default is 2',
        type=int,
        default=2,
    )
    parser.add_argument(
        '--environment-count',
        metavar='',
        help=(
            'Number of environments to create, default is 2'
        ),
        type=int,
        default=2,
    )
    parser.add_argument(
        '--template-count',
        metavar='',
        help=(
            'Number of templates to create per project, default is 2'
        ),
        type=int,
        default=2,
    )
    parser.add_argument(
        '--parameter-count',
        metavar='',
        help='Number of parameters to create in each project, default is 5 per project',
        type=int,
        default=2,
    )

    return parser.parse_args()


def create_projects(count, parent_project_name=None):
    created_projects = []
    parent_project = None

    if parent_project_name:
        parent_project = helpers.get_object_by_name(
            parent_project_name,
            'projects',
            _api_url,
            _headers
        )
        if parent_project is None:
            console.log(f'No parent project named {parent_project_name}!')

    i = 0
    while i < count:
        project_name = PROJECT_PREFIX + shortuuid.uuid()
        project = helpers.create_project(project_name, _api_url, _headers, parent_project)
        created_projects.append(project)
        i += 1

    console.log(f'Created {len(created_projects)} projects')


def create_envs(count, parent):
    i = 0
    while i < count:
        env_name = ENVIRONMENT_PREFIX + shortuuid.uuid()
        env = helpers.create_environment(env_name, _api_url, _headers, parent)
        _envs.append(env)
        i += 1


def create_params(count, project):
    i = 0
    param_name = PARAMETER_PREFIX + shortuuid.uuid()
    while i < count:
        helpers.create_parameter(param_name, project, _api_url, _headers)


def delete_all_parameters():
    projects = helpers.get_objects_list('projects', _api_url, _headers)
    for project in projects:
        helpers.delete_project_parameters(project, _api_url, _headers)


def delete_all_projects(force=False):
    console.print('Deleting all projects')
    projects = helpers.get_all_top_level_projects(_api_url, _headers)

    if not projects:
        return None

    for project in projects:
        helpers.delete_project(project, _api_url, _headers, force)

    return True


def delete_single_project(project_root_name=None, force=False):
    project = helpers.get_object_by_name(project_root_name, 'projects', _api_url, _headers)

    if not project:
        return None

    console.print(f"Deleting project: {project.get('name')} and all dependents")
    # helpers.delete_project(project, _api_url, _headers, force)
    return True


def main():
    args = parse_args()
    profile = args.profile

    # validate options
    if args.force and args.delete is None:
        console.print('force is ignored as it is only used with delete operations')

    if args.create and args.delete:
        console.print('Ambiguous operations, create and delete cannot be used together')
        exit(EXIT_ERR)

    global _api_key
    _api_key = helpers.get_profile_api_key(profile)
    if not _api_key:
        exit('Profile is missing the target API key, check the CloudTruth CLI config. Exiting.')

    global _api_url
    _api_url = f'{helpers.get_profile_url(profile)}/api/v1'
    if not _api_url:
        exit('Profile is missing the target API url, check the CloudTruth CLI config. Exiting.')

    global _headers
    _headers = {'Authorization': f'Api-Key {_api_key}'}

    global _projects
    _projects = []

    global _envs
    _envs = []

    global _template_uris
    _template_uris = []

    if args.create or args.delete:
        if args.projects and args.create:
            project_count = args.project_count
            project_root_name = args.project_root_name
            create_projects(project_count, project_root_name)
            if args.levels:
                projects = helpers.get_objects_list('projects', _api_url, _headers)
                i = 0
                while i < args.levels:
                    for project in projects:
                        create_projects(project_count, project.get('name'))
                        i += 1
        else:
            if args.projects:
                if args.project_root_name:
                    result = delete_single_project(args.project_root_name, args.force)
                    if not result:
                        console.print('Project not found')
                        exit(EXIT_ERR)
                else:
                    result = delete_all_projects(args.force)
                    if not result:
                        console.print('No projects found')
        if args.environments and args.create:
            console.print('creating environments')
        else:
            if args.environments:
                console.print('deleting environments')
        if args.templates and args.create:
            console.print('creating templates')
        else:
            if args.templates:
                console.print('deleting templates')

    # # reset org
    # if args.reset_org and args.force:
    #     console.print('Nuking everything')
    #     # implement y/n
    #     foo = helpers.nuke()
    #     console.print('Nuke complete')
    #     exit(foo)

    # # create environments
    # env_count = args.envs
    # parent_env_name = args.base_env
    # if env_count > 0 and args.delete_force is not True:
    #     console.print('Creating environments')
    #     parent_uri = helpers.get_object_by_name(
    #         parent_env_name,
    #         'environments',
    #         _api_url,
    #         _headers
    #     )

    #     create_envs(env_count, parent_uri)
    #     console.print(f'Created {env_count} new environments under the {parent_env_name} environment')

    # # create parameters
    # param_count = args.params
    # if param_count > 0 and args.delete_force is not True:
    #     console.print('Creating parameters')
    #     for project in _projects:
    #         create_params(param_count, project)
    #         console.print(f'Created {param_count} parameters in each of {_projects.count()} projects' )

    # if args.delete_project_force:
    #     delete_params = True
    #     project = args.base_project
    #     console.print(
    #         f"Deleting all child projects under parent {project['name']}, this includes " +
    #         "each project's parameters"
    #     )

    #     helpers.delete_project(project, _api_url, _headers, delete_params)

    # TODO: implement template create
    # TODO: implement destroy_params
    # TODO: implement destroy_envs
    # TODO: implement destroy_projects
    # TODO: implement destroy_all
    # TODO: implement store data?


if __name__ == "__main__":
    main()
