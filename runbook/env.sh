# runbook/env.sh
export AWS_REGION=eu-west-1
export PROJ=notesapp
export DOMAIN=example.com
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export WEB_BUCKET=$PROJ-$ACCOUNT_ID-web