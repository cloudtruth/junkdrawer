#!/usr/bin/env bash

# fail fast
set -e

addParamAndSecret() {
    local project=$1
    shift
    local env=$1
    shift
    local id=$1
    shift
    cloudtruth --project ${project} --env ${env} param set "param-${id}" --value "param-${project}-${env}-${id}" "$@"
    cloudtruth --project ${project} --env ${env} param set "secret-${id}" --value "secret-${project}-${env}-${id}" --secret true "$@"
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

base_project=${base_project:-base}
child_project=${child_project:-child}
base_count=${base_count:-300}
child_count=${child_count:-50}
production_step=${production_step:-5}
staging_step=${staging_step:-6}

echo "Set the following to affect how many params/secrets get created across envs"
echo "e.g."
echo "  base_count=10 child_count=5 production_step=2 staging_step=2 $(basename $0)"
echo
echo "Current values:"
echo base_project=${base_project} - the base project name
echo child_project=${child_project} - the child project name
echo base_count=${base_count} - how many params and secrets to create in base project
echo child_count=${child_count} - how many params and secrets to create in child project
echo production_step=${production_step} - every Nth item gets overriden for production
echo staging_step=${staging_step} - every Nth item gets overriden for staging
echo

cloudtruth project set "${base_project}"
cloudtruth project set "${child_project}" --parent "${base_project}"
now=$(date +"%Y-%m-%d_%H-%M")
cloudtruth environment tag set production testTag_${now}
cloudtruth environment tag set staging testTag_${now}

# Add templates to base project
cloudtruth --project "${base_project}" template set json --body <(cat <<'EOF'
{
{%- for param in cloudtruth.parameters %}
  "{{param[0]}}": "{{param[1]}}"{% unless forloop.last %};{% endunless %}
{%- endfor %}
}
EOF
)

cloudtruth --project "${base_project}" template set yaml --body <(cat <<'EOF'
# {{ cloudtruth.environment }}
{% for param in cloudtruth.parameters -%}
{{param[0]}}: {{param[1]}}
{% endfor -%}
EOF
)

# Add templates to child project
cloudtruth --project "${child_project}" template set dotenv --body <(cat <<'EOF'
{%- for param in cloudtruth.parameters -%}
{{param[0] | upcase}}={{param[1]}}
{% endfor -%}
EOF
)

# Adds params and secrets to base project
seq 1 1 $base_count | while read x; do
    addParamAndSecret "${base_project}" default "${base_project}-${x}"
done

# Adds non-override params and secrets to child project
seq 1 1 $child_count| while read x; do
    addParamAndSecret "${child_project}" default "${child_project}-${x}"
done

# Adds override params and secrets to child project
seq 1 1 $child_count| while read x; do
    addParamAndSecret "${child_project}" default "${base_project}-${x}" --create-child
done

# Sets production values for some params in base project
seq 1 $production_step $base_count | while read x; do
    addParamAndSecret "${base_project}" production "${base_project}-${x}"
done

# Sets staging values for some params in base project
seq 1 $staging_step $base_count | while read x; do
    addParamAndSecret "${base_project}" staging "${base_project}-${x}"
done

# Sets production values for some params in child project
seq 1 $production_step $child_count | while read x; do
    addParamAndSecret "${child_project}" production "${child_project}-${x}"
done

# Sets staging values for some params in child project
seq 1 $staging_step $child_count | while read x; do
    addParamAndSecret "${child_project}" staging "${child_project}-${x}"
done

cloudtruth environment tag set production stable
cloudtruth environment tag set staging stable
