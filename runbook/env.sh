#!/bin/bash
set -euo pipefail

export AWS_REGION="eu-west-1"
export AWS_DEFAULT_REGION="eu-west-1"

PROJECT_PREFIX="/notesapp/outputs"
# Helper function to write to SSM Parameter Store
save_to_ssm() {
    local param_name=$1
    local param_value=$2
    
    echo "Storing $param_name ($param_value) in SSM..."
    aws ssm put-parameter \
        --name "${PROJECT_PREFIX}/${param_name}" \
        --value "$param_value" \
        --type "String" \
        --overwrite > /dev/null
}

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Store infrastructure outputs in SSM Parameter Store
save_to_ssm "region" "eu-west-1"
save_to_ssm "proj" "notesapp"
save_to_ssm "account_id" "$ACCOUNT_ID"
save_to_ssm "email" "aziz.nasri.dev@gmail.com"
# save_to_ssm "domain" ""

echo "All infrastructure outputs successfully stored in SSM Parameter Store!"