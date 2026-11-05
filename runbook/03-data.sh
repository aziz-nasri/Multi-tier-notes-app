#!/bin/bash
set -euo pipefail

# Buckets
WEB_BUCKET="${PROJ}-${ACCOUNT_ID}-web";  ART_BUCKET="${PROJ}-${ACCOUNT_ID}-artifacts"
for b in $WEB_BUCKET $ART_BUCKET; do
  aws s3api create-bucket --bucket $b --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION
  aws s3api put-public-access-block --bucket $b --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket $b --versioning-configuration Status=Enabled
done
aws s3api put-bucket-encryption --bucket $ART_BUCKET --server-side-encryption-configuration \
  "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KMS_KEY\"},\"BucketKeyEnabled\":true}]}"

# RDS
PG_VER=$(aws rds describe-db-engine-versions --engine postgres --default-only --query 'DBEngineVersions[0].EngineVersion' --output text)

aws rds create-db-subnet-group --db-subnet-group-name notes-db-subnets \
  --db-subnet-group-description "notes data tier" --subnet-ids $DATA_A $DATA_B

aws rds create-db-instance --db-instance-identifier notes-db \
  --engine postgres --engine-version $PG_VER --db-instance-class db.t4g.micro \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted --kms-key-id $KMS_KEY \
  --master-username notesadmin --manage-master-user-password --master-user-secret-kms-key-id $KMS_KEY \
  --db-name notes --db-subnet-group-name notes-db-subnets --vpc-security-group-ids $DB_SG \
  --no-publicly-accessible --no-multi-az --backup-retention-period 7 \
  --preferred-backup-window 02:00-03:00 --preferred-maintenance-window sun:03:30-sun:04:30 \
  --enable-cloudwatch-logs-exports postgresql --deletion-protection --copy-tags-to-snapshot \
  --auto-minor-version-upgrade --tags Key=Project,Value=$PROJ Key=Backup,Value=true
aws rds wait db-instance-available --db-instance-identifier notes-db

DB_HOST=$(aws rds describe-db-instances --db-instance-identifier notes-db --query 'DBInstances[0].Endpoint.Address' --output text)
DB_SECRET_ARN=$(aws rds describe-db-instances --db-instance-identifier notes-db --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

# adding least-privilege policy to ec2
cat > ec2-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"$DB_SECRET_ARN"},
 {"Effect":"Allow","Action":"kms:Decrypt","Resource":"arn:aws:kms:$AWS_REGION:$ACCOUNT_ID:key/$KMS_KEY"},
 {"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::$ART_BUCKET/*"}]}
EOF
aws iam put-role-policy --role-name notes-ec2-role --policy-name notes-app-access --policy-document file://ec2-policy.json

# exporting variables
export DB_HOST
export DB_SECRET_ARN
export ART_BUCKET
export WEB_BUCKET