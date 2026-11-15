#!/bin/bash
set -euo pipefail

PROJECT_PREFIX="/notesapp/outputs"
# Helper function to write to SSM Parameter Store
save_to_ssm() {
    local param_name=$1
    local param_value=$2
    
    echo "Storing $param_name in SSM..."
    aws ssm put-parameter \
        --name "${PROJECT_PREFIX}/${param_name}" \
        --value "$param_value" \
        --type "String" \
        --overwrite > /dev/null
}

echo "Fetching project configuration from SSM Parameter Store..."
ACCOUNT_ID=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/account_id" --query "Parameter.Value" --output text)
PROJ=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/proj" --query "Parameter.Value" --output text)
AWS_REGION=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/region" --query "Parameter.Value" --output text)
DATA_A=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/data_a" --query "Parameter.Value" --output text)
DATA_B=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/data_b" --query "Parameter.Value" --output text)
DB_SG=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/db_sg" --query "Parameter.Value" --output text)
KMS_KEY_FOR_ARTI=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/key_for_arti" --query "Parameter.Value" --output text)


# Buckets
WEB_BUCKET="${PROJ}-${ACCOUNT_ID}-web";  ART_BUCKET="${PROJ}-${ACCOUNT_ID}-artifacts"
echo "Creating S3 buckets ($WEB_BUCKET and $ART_BUCKET)..."
for b in $WEB_BUCKET $ART_BUCKET; do
  echo "Configuring public access block and versioning for: $b"
  aws s3api create-bucket --bucket $b --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION
  aws s3api put-public-access-block --bucket $b --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket $b --versioning-configuration Status=Enabled
done

save_to_ssm "art_bucket" "$ART_BUCKET"
save_to_ssm "web_bucket" "$WEB_BUCKET"

echo "Applying KMS encryption configuration to artifacts bucket..."
aws s3api put-bucket-encryption --bucket $ART_BUCKET --server-side-encryption-configuration \
  "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KMS_KEY_FOR_ARTI\"},\"BucketKeyEnabled\":true}]}"

# RDS
echo "Fetching default PostgreSQL engine version..."
PG_VER=$(aws rds describe-db-engine-versions --engine postgres --default-only --query 'DBEngineVersions[0].EngineVersion' --output text)

echo "Creating RDS DB subnet group..."
aws rds create-db-subnet-group --db-subnet-group-name notes-db-subnets \
  --db-subnet-group-description "notes data tier" --subnet-ids $DATA_A $DATA_B

echo "Provisioning RDS PostgreSQL instance (notes-db)..."
aws rds create-db-instance --db-instance-identifier notes-db \
  --engine postgres --engine-version $PG_VER --db-instance-class db.t4g.micro \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted --kms-key-id $KMS_KEY_FOR_ARTI \
  --master-username notesadmin --manage-master-user-password --master-user-secret-kms-key-id $KMS_KEY_FOR_ARTI \
  --db-name notes --db-subnet-group-name notes-db-subnets --vpc-security-group-ids $DB_SG \
  --no-publicly-accessible --no-multi-az --backup-retention-period 1 \
  --preferred-backup-window 02:00-03:00 --preferred-maintenance-window sun:03:30-sun:04:30 \
  --enable-cloudwatch-logs-exports postgresql --deletion-protection --copy-tags-to-snapshot \
  --auto-minor-version-upgrade --tags Key=Project,Value=$PROJ Key=Backup,Value=true

echo "Waiting for RDS instance to become available (this may take a few minutes)..."
aws rds wait db-instance-available --db-instance-identifier notes-db

echo "Retrieving database endpoint and secret ARN..."
DB_HOST=$(aws rds describe-db-instances --db-instance-identifier notes-db --query 'DBInstances[0].Endpoint.Address' --output text)
DB_SECRET_ARN=$(aws rds describe-db-instances --db-instance-identifier notes-db --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

save_to_ssm "db_host" "$DB_HOST"
aws ssm put-parameter \
        --name "${PROJECT_PREFIX}/db_secret_arn" \
        --value "$DB_SECRET_ARN" \
        --type "SecureString" \
        --overwrite

# adding least-privilege policy to ec2
echo "Creating and attaching least-privilege IAM policy for EC2..."
cat > ec2-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"$DB_SECRET_ARN"},
 {"Effect":"Allow","Action":"kms:Decrypt","Resource":"arn:aws:kms:$AWS_REGION:$ACCOUNT_ID:key/$KMS_KEY_FOR_ARTI"},
 {"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::$ART_BUCKET/*"}]}
EOF
aws iam put-role-policy --role-name notes-ec2-role --policy-name notes-app-access --policy-document file://ec2-policy.json