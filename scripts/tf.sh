#!/usr/bin/env bash
# Run Terraform for one stack with one environment's settings and state.
#
#   scripts/tf.sh <foundation|platform> <terraform command> [args...]
#   ENV=dev scripts/tf.sh platform plan        # ENV defaults to prod
#
# Each stack keeps per-environment files in infra/<stack>/envs/:
#   <env>.tfvars        variable values (region, names, sizes...)
#   <env>.backend.hcl   where that environment's state lives
#   <env>.local.tfvars  optional, git-ignored: values that must stay out of a public repo (your IP)
set -euo pipefail

usage="usage: [ENV=<env>] scripts/tf.sh <foundation|platform> <command> [args...]"
stack=${1:?$usage}; shift
cmd=${1:?$usage}; shift
env=${ENV:-prod}
dir="$(cd "$(dirname "$0")/.." && pwd)/infra/$stack"

for f in "envs/$env.tfvars" "envs/$env.backend.hcl"; do
  [ -f "$dir/$f" ] || { echo "missing infra/$stack/$f" >&2; exit 1; }
done

tf() { terraform -chdir="$dir" "$@"; }

varfiles=(-var-file="envs/$env.tfvars")
[ -f "$dir/envs/$env.local.tfvars" ] && varfiles+=(-var-file="envs/$env.local.tfvars")

# -reconfigure only switches which state file this folder points at; it never moves or copies state.
init() { tf init -input=false -reconfigure -backend-config="envs/$env.backend.hcl" "$@"; }

case "$cmd" in
  init) init "$@"; exit ;;
esac
init >/dev/null

case "$cmd" in
  apply)
    # A saved plan already contains its variables; Terraform refuses -var-file with one.
    if [ $# -gt 0 ] && [[ "${!#}" == *.tfplan ]]; then tf apply "$@"; else tf apply "${varfiles[@]}" "$@"; fi ;;
  plan|destroy|import|refresh|console)
    tf "$cmd" "${varfiles[@]}" "$@" ;;
  *)
    tf "$cmd" "$@" ;;   # output, state, fmt, validate, show...
esac
