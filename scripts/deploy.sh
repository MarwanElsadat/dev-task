#!/usr/bin/env bash
# Deploys the dev-task source tree to the default org.
# Usage: ./scripts/deploy.sh [-o <org-alias>] [-c]
#   -o  org alias (defaults to project default)
#   -c  also run all local Apex tests after deploy

set -euo pipefail

ORG_FLAG=""
RUN_TESTS=false

while getopts "o:c" opt; do
  case $opt in
    o) ORG_FLAG="-o $OPTARG" ;;
    c) RUN_TESTS=true ;;
    *) echo "Usage: $0 [-o <org-alias>] [-c]"; exit 1 ;;
  esac
done

echo "==> Deploying source to org${ORG_FLAG:+ ($ORG_FLAG)}"
sf project deploy start -d force-app $ORG_FLAG

if [ "$RUN_TESTS" = true ]; then
  echo "==> Running local Apex tests"
  sf apex run test --code-coverage --result-format human --wait 10 $ORG_FLAG
fi

echo "==> Done"
