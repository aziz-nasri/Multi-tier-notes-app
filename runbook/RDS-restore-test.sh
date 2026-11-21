#!/bin/bash
set -euo pipefail

PROJECT_PREFIX="/notesapp/outputs"
DB_SG=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/db_sg" --query "Parameter.Value" --output text)
T0=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Restore started at (T0): $T0"

aws rds restore-db-instance-to-point-in-time \
  --region eu-west-1 \
  --source-db-instance-identifier notes-db \
  --target-db-instance-identifier notes-db-pitr-test \
  --use-latest-restorable-time \
  --db-subnet-group-name notes-db-subnets \
  --vpc-security-group-ids $DB_SG \
  --no-publicly-accessible

aws rds wait db-instance-available \
  --region eu-west-1 \
  --db-instance-identifier notes-db-pitr-test

T_AVAIL=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Instance available at (T_available): $T_AVAIL"