#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/notebook-env.sh"
mkdir -p "$STATE/aap"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  doormat aws -a "$DOORMAT_AWS_ACCOUNT" export > "$STATE/aap/aws.env.tmp"
  mv "$STATE/aap/aws.env.tmp" "$STATE/aws-session.env"
  source "$STATE/aws-session.env"
fi
if [[ ! -f "$STATE/aap/deployment-input.json" ]]; then
  ami=$(aws ec2 describe-images --owners 309956199498 \
    --filters 'Name=name,Values=RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3' 'Name=architecture,Values=x86_64' \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  jq --arg ami "$ami" --arg cidr "$(curl -fsS https://checkip.amazonaws.com)/32" \
    '{vpc_id,subnet_ids,zone_id,domain:(.domain | sub("^vault-vm\\."; "aap-vm.")),ami_id:$ami,admin_cidr:$cidr}' \
    "$STATE/deployment-input.json" > "$STATE/aap/deployment-input.json"
fi
cp "$STATE/aap/deployment-input.json" "$VM_ROOT/terraform/aap/runtime.auto.tfvars.json"
terraform -chdir="$VM_ROOT/terraform/aap" init -input=false
terraform -chdir="$VM_ROOT/terraform/aap" validate
terraform -chdir="$VM_ROOT/terraform/aap" plan -input=false -out="$STATE/aap/infrastructure.tfplan"
terraform -chdir="$VM_ROOT/terraform/aap" show -json "$STATE/aap/infrastructure.tfplan" |
  jq -e 'all(.resource_changes[]?; .change.actions | index("delete") | not)' >/dev/null
terraform -chdir="$VM_ROOT/terraform/aap" apply -input=false "$STATE/aap/infrastructure.tfplan"
terraform -chdir="$VM_ROOT/terraform/aap" output -json | jq 'with_entries(.value=.value.value)' > "$STATE/aap/infrastructure.json"
jq '{aap_address,instance_id,public_ip,private_ip}' "$STATE/aap/infrastructure.json"
