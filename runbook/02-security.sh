#!/bin/bash
set -euo pipefail

# security groups
mk_sg(){ aws ec2 create-security-group --group-name $1 --description "$1" --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJ}]" --query GroupId --output text; }
ALB_SG=$(mk_sg alb-sg); APP_SG=$(mk_sg app-sg); DB_SG=$(mk_sg db-sg)

CF_PL=$(aws ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text)

aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,PrefixListIds=[{PrefixListId=$CF_PL}]"
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$ALB_SG}]"
aws ec2 authorize-security-group-ingress --group-id $DB_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$APP_SG}]"

# Replace default allow-all egress with scoped egress
for sg in $ALB_SG $APP_SG $DB_SG; do
  aws ec2 revoke-security-group-egress --group-id $sg \
    --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]'; done

aws ec2 authorize-security-group-egress --group-id $ALB_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$APP_SG}]"
aws ec2 authorize-security-group-egress --group-id $APP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$DB_SG}]" \
                   "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]"

#IAM role
cat > trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name notes-ec2-role --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name notes-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name notes-ec2-role --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam create-instance-profile --instance-profile-name notes-ec2-profile
aws iam add-role-to-instance-profile --instance-profile-name notes-ec2-profile --role-name notes-ec2-role


# KMS keys
cat << EOF > artifact-kms-policy.json
{
  "Version": "2012-10-17",
  "Id": "artifact-bucket-cmk-policy",
  "Statement": [
    {
      "Sid": "EnableRootAccountAdministration",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowEC2InstanceRuntimeRead",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:role/notes-ec2-role"
      },
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowS3ServiceAccess",
      "Effect": "Allow",
      "Principal": {
        "Service": "s3.amazonaws.com"
      },
      "Action": [
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    }
  ]
}
EOF
KMS_KEY_FOR_ARTI=$(aws kms create-key --description "$PROJ CMK" --tags TagKey=Project,TagValue=$PROJ \
  --query KeyMetadata.KeyId --output text)
aws kms create-alias --alias-name alias/$PROJ --target-key-id $KMS_KEY_FOR_ARTI
aws kms enable-key-rotation --key-id $KMS_KEY_FOR_ARTI

rm artifact-kms-policy.json

KMS_KEY_ARN_FOR_CT=$(aws kms create-key \
    --description "KMS key for CloudTrail log encryption" \
    --query "KeyMetadata.Arn" \
    --output text \
    --region "$AWS_REGION")

aws kms create-alias \
    --alias-name "alias/notes-cloudtrail-key" \
    --target-key-id "$KMS_KEY_ARN_FOR_CT" \
    --region "${AWS_REGION}"

cat << EOF > kms-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow CloudTrail to encrypt logs",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudtrail.amazonaws.com"
      },
      "Action": [
        "kms:GenerateDataKey*",
        "kms:Decrypt"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:EncryptionContext:aws:cloudtrail:arn": "arn:aws:cloudtrail:*:${ACCOUNT_ID}:trail/*"
        }
      }
    }
  ]
}
EOF

aws kms put-key-policy \
    --key-id "$KMS_KEY_ARN_FOR_CT" \
    --policy-name "default" \
    --policy file://kms-policy.json \
    --region "${ACCOUNT_ID}"

aws kms enable-key-rotation --key-id $KMS_KEY_ARN_FOR_CT

rm kms-policy.json

cat << EOF > backup-kms-policy.json
{
  "Version": "2012-10-17",
  "Id": "aws-backup-cmk-policy",
  "Statement": [
    {
      "Sid": "EnableRootAccountAdministration",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowAWSBackupServicePrincipal",
      "Effect": "Allow",
      "Principal": {
        "Service": "backup.amazonaws.com"
      },
      "Action": [
        "kms:CreateGrant",
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
        "kms:RetireGrant"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowAWSBackupServiceLinkedRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:role/aws-service-role/backup.amazonaws.com/AWSServiceRoleForBackup"
      },
      "Action": [
        "kms:CreateGrant",
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
        "kms:RetireGrant"
      ],
      "Resource": "*"
    }
  ]
}
EOF

KMS_KEY_ARN_FOR_BACKUP=$(aws kms create-key \
    --description "KMS key for AWS Backup Vault" \
    --policy file://backup-kms-policy.json \
    --query "KeyMetadata.Arn" \
    --output text \
    --region "$AWS_REGION")

aws kms create-alias \
    --alias-name "alias/notes-backup-key" \
    --target-key-id "$KMS_KEY_ARN" \
    --region "$AWS_REGION"

aws kms enable-key-rotation --key-id $KMS_KEY_ARN_FOR_BACKUP

rm backup-kms-policy.json

# exporting variables 
export KMS_KEY_FOR_ARTI
export KMS_KEY_ARN_FOR_CT
export KMS_KEY_ARN_FOR_BACKUP
export APP_SG
export ALB_SG
export DB_SG