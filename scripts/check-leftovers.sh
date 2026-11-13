#!/usr/bin/env bash
# Lists billable resources that should not exist after session-down. Exit code 1 if any are found, or if a
# check couldn't run (an AWS error must never read as "none").
# Account-wide: if you run other things in us-east-1, some lines may be yours and expected.
set -uo pipefail
found=0
check() {   # check <label> <aws cli args…>
  local out
  if ! out=$(aws "${@:2}" --output text 2>&1); then
    echo "❓ $1: check failed: $(echo "$out" | grep -m1 .)"; found=1; return
  fi
  out=$(echo "$out" | tr -s '\t\r\n' ' ')
  if [ -n "${out// /}" ] && [ "$out" != "None " ]; then echo "⚠️  $1: $out"; found=1; else echo "✅ $1: none"; fi
}
check "EKS clusters"            eks list-clusters --query 'clusters'
check "k8s load balancers"      elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-')].LoadBalancerName"
check "Karpenter instances"     ec2 describe-instances --filters Name=tag-key,Values=karpenter.sh/nodepool Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId'
check "NAT gateways"            ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId'
check "Unattached EBS volumes"  ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
check "Unattached Elastic IPs"  ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'
check "RDS instances"           rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
check "WAF web ACLs"            wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].Name'
[ "$found" = 0 ] && echo "All clear: nothing billable left from the platform." || echo "Something is still running, or couldn't be checked: see ⚠️/❓ lines."
exit "$found"
