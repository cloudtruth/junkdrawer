#!/usr/bin/env bash

# fail fast
set -e

addParamAndSecret() {
    local project=$1
    local env=$2
    local id=$3
    cloudtruth --project ${project} --env ${env} param set "${project}Param${id}" --value "${project}ParamVal${env}${id}"
    cloudtruth --project ${project} --env ${env} param set "${project}Param${id}Secret" --value "${project}SecretVal${env}${id}" --secret true
}

rand() {
    local max=$1
    echo $(( RANDOM % max + 1))
}

echo "Set CLOUDTRUTH_* to use different config"
echo "e.g."
echo "  CLOUDTRUTH_PROFILE=staging $(basename $0)"
echo
echo "Current environment values:"
env | grep CLOUDTRUTH_ || true
echo

base_count=${base_count:-300}
child_count=${child_count:-50}
production_step=${production_step:-5}
staging_step=${staging_step:-6}

echo "Set the following to affect how many params/secrets get created across envs"
echo "e.g."
echo "  base_count=10 child_count=5 production_step=2 staging_step=2$(basename $0)"
echo
echo "Current values:"
echo base_count=${base_count} - how many params and secrets to create in base project
echo child_count=${child_count} - how many params and secrets to create in child project
echo production_step=${production_step} - every Nth item gets overriden for production
echo staging_step=${staging_step} - every Nth item gets overriden for staging
echo

cloudtruth project set base
cloudtruth project set child --parent base
now=$(date +"%Y-%m-%d_%H-%M")
cloudtruth environment tag set production testTag_${now}
cloudtruth environment tag set staging testTag_${now}

# Adds params and secrets to base project
seq 1 1 $base_count | while read x; do
    addParamAndSecret base default $x
done

# Adds non-override params and secrets to child project
seq 1 1 $child_count| while read x; do
    addParamAndSecret child default "${x}-child"
done

# Adds override params and secrets to child project
seq 1 1 $child_count| while read x; do
    addParamAndSecret child default $x
done

# Sets production values for some params in base project
seq 1 $production_step $base_count | while read x; do
    addParamAndSecret base production $x
done

# Sets staging values for some params in base project
seq 1 $staging_step $base_count | while read x; do
    addParamAndSecret base staging $x
done

# Sets production values for some params in child project
seq 1 $production_step $child_count | while read x; do
    addParamAndSecret child production $x
done

# Sets staging values for some params in child project
seq 1 $staging_step $child_count | while read x; do
    addParamAndSecret child staging $x
done

cloudtruth environment tag set production stable
cloudtruth environment tag set staging stable
