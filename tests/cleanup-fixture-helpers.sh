#!/usr/bin/env bash

raw_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

provider_secret_projection_sha256() {
  local inventory=$1
  jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
    "$inventory" | shasum -a 256 | awk '{print $1}'
}

prepare_saved_plan_manifest() {
  local output_dir=$1 manifest=$2 layer plan_path plan_sha
  local -a layers=(
    environments/prod/04-workloads/argocd
    environments/dev/04-workloads/argocd
    environments/prod/03-platform
    environments/dev/03-platform
    environments/prod/02-eks
    environments/dev/02-eks
    environments/prod/01-network
    environments/dev/01-network
  )
  mkdir -p "$output_dir"
  jq -n '{schemaVersion:"course.saved-destroy-plans/v1",status:"REVIEWED",reviewedAt:"2026-09-03T00:10:00Z",plans:[]}' >"$manifest"
  for layer in "${layers[@]}"; do
    plan_path="$output_dir/${layer//\//__}.tfplan"
    printf 'saved destroy plan for %s\n' "$layer" >"$plan_path"
    plan_sha=$(raw_sha256 "$plan_path")
    jq --arg layer "$layer" --arg path "$plan_path" --arg sha "$plan_sha" \
      '.plans += [{layer:$layer,path:$path,sha256:$sha}]' "$manifest" >"$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
  done
}

prepare_realistic_destroy_plan_jsons() {
  local output_dir=$1 layer environment semantic_layer address type id ownership_input
  local -a layers=(
    environments/prod/04-workloads/argocd
    environments/dev/04-workloads/argocd
    environments/prod/03-platform
    environments/dev/03-platform
    environments/prod/02-eks
    environments/dev/02-eks
    environments/prod/01-network
    environments/dev/01-network
  )
  mkdir -p "$output_dir"
  for layer in "${layers[@]}"; do
    environment=${layer#environments/}
    environment=${environment%%/*}
    case "$layer" in
      */04-workloads/argocd)
        semantic_layer=workloads
        address=terraform_data.course_ownership
        type=terraform_data
        id="ownership-$environment"
        ownership_input=$(jq -cn --arg env "$environment" '{
          CourseId:"course-2026", AccountId:"123456789012", Region:"ap-northeast-2",
          Project:"playdevops", Environment:$env, Layer:"workloads", ManagedBy:"Terraform"
        }')
        jq -n --arg address "$address" --arg type "$type" --arg id "$id" --argjson input "$ownership_input" '{
          format_version:"1.2", resource_changes:[
            {address:$address,mode:"managed",type:$type,name:"course_ownership",
             change:{actions:["delete"],before:{id:$id,input:$input,output:$input},after:null}},
            {address:"helm_release.argocd",mode:"managed",type:"helm_release",name:"argocd",
             change:{actions:["delete"],before:{id:"argocd",name:"argocd",namespace:"argocd"},after:null}}
          ]
        }' >"$output_dir/${layer//\//__}.json"
        ;;
      */03-platform)
        semantic_layer=platform
        jq -n --arg env "$environment" --arg layer "$semantic_layer" '{
          format_version:"1.2", resource_changes:[
            {address:"terraform_data.external_secrets_ownership_gate",mode:"managed",type:"terraform_data",
             name:"external_secrets_ownership_gate",change:{actions:["delete"],before:{id:("gate-"+$env)},after:null}},
            {address:"module.reloader[0].helm_release.this",mode:"managed",type:"helm_release",name:"this",
             change:{actions:["delete"],before:{id:"reloader",name:"reloader",namespace:"kube-system"},after:null}},
            {address:"aws_secretsmanager_secret.sample_app_runtime",mode:"managed",type:"aws_secretsmanager_secret",
             name:"sample_app_runtime",change:{actions:["delete"],before:{
               id:("arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:"+$env+"-runtime"),
               tags_all:{CourseId:"course-2026",Project:"playdevops",Environment:$env,Layer:$layer,ManagedBy:"Terraform"}
             },after:null}}
          ]
        }' >"$output_dir/${layer//\//__}.json"
        ;;
      */02-eks)
        semantic_layer=eks
        id="arn:aws:eks:ap-northeast-2:123456789012:cluster/${environment}-playdevops-eks"
        jq -n --arg env "$environment" --arg layer "$semantic_layer" --arg id "$id" '{
          format_version:"1.2", resource_changes:[{
            address:"module.eks_cluster.aws_eks_cluster.cluster",mode:"managed",type:"aws_eks_cluster",name:"cluster",
            change:{actions:["delete"],before:{id:$id,
              tags_all:{CourseId:"course-2026",Project:"playdevops",Environment:$env,Layer:$layer,ManagedBy:"Terraform"}
            },after:null}
          }]
        }' >"$output_dir/${layer//\//__}.json"
        ;;
      */01-network)
        semantic_layer=network
        id="nat-${environment}-001"
        jq -n --arg env "$environment" --arg layer "$semantic_layer" --arg id "$id" '{
          format_version:"1.2", resource_changes:[{
            address:"module.vpc.aws_nat_gateway.this[0]",mode:"managed",type:"aws_nat_gateway",name:"this",
            change:{actions:["delete"],before:{id:$id,
              tags_all:{CourseId:"course-2026",Project:"playdevops",Environment:$env,Layer:$layer,ManagedBy:"Terraform"}
            },after:null}
          }]
        }' >"$output_dir/${layer//\//__}.json"
        ;;
    esac
  done
}

prepare_cleanup_fixtures() {
  local root=$1 output_dir=$2 region=$3
  local inventory_sha freeze_sha removal_sha decisions_sha pre_destroy_sha provider_sha
  jq --arg region "$region" '
    .region=$region |
    .resources |= map(
      if (.id | startswith("arn:aws:")) then
        .id |= gsub("ap-northeast-2";$region)
      else . end
    )
  ' "$root/tests/fixtures/cleanup-ownership-valid.json" >"$output_dir/inventory.json"
  inventory_sha=$(raw_sha256 "$output_dir/inventory.json")

  jq --arg region "$region" --arg inventory "$inventory_sha" '
    .region=$region | .inventorySha256=$inventory |
    .decisions |= map(if (.id | startswith("arn:aws:")) then .id |= gsub("ap-northeast-2";$region) else . end)
  ' "$root/tests/fixtures/cleanup-retain-decisions-valid.json" >"$output_dir/decisions.json"

  jq --arg region "$region" '
    .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/cleanup-gitops-freeze-valid.json" >"$output_dir/freeze.json"
  freeze_sha=$(raw_sha256 "$output_dir/freeze.json")
  provider_sha=$(provider_secret_projection_sha256 "$output_dir/inventory.json")

  jq --arg region "$region" --arg freeze "$freeze_sha" --arg provider "$provider_sha" '
    .freezeEvidenceSha256=$freeze | .providerSecrets.inventorySha256=$provider |
    .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/cleanup-gitops-removal-valid.json" >"$output_dir/removal.json"
  removal_sha=$(raw_sha256 "$output_dir/removal.json")

  jq --arg region "$region" --arg removal "$removal_sha" '
    .region=$region | .gitopsRemovalSha256=$removal |
    .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/kubernetes-pre-destroy-valid.json" >"$output_dir/pre-destroy.json"

  decisions_sha=$(raw_sha256 "$output_dir/decisions.json")
  pre_destroy_sha=$(raw_sha256 "$output_dir/pre-destroy.json")
  jq --arg inventory "$inventory_sha" --arg decisions "$decisions_sha" \
    --arg pre "$pre_destroy_sha" --arg removal "$removal_sha" '
    .inventorySha256=$inventory | .retainDecisionsSha256=$decisions |
    .kubernetesPreDestroySha256=$pre | .gitopsRemovalSha256=$removal
  ' "$root/tests/fixtures/cleanup-residual-zero-$region.json" >"$output_dir/residual.json"
}
