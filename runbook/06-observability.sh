#!/bin/bash
set -euo pipefail

TOPIC=$(aws sns create-topic --name notes-alerts --query TopicArn --output text)
aws sns subscribe --topic-arn $TOPIC --protocol email --notification-endpoint you@example.com

ALB_DIM=$(echo $ALB_ARN | cut -d/ -f2-)
aws cloudwatch put-metric-alarm \
    --alarm-name notes-alb-5xx \
    --namespace AWS/ApplicationELB \
    --metric-name HTTPCode_Target_5XX_Count \
    --dimensions Name=LoadBalancer,Value=$ALB_DIM \
    --statistic Sum \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 10 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --treat-missing-data notBreaching --alarm-actions $TOPIC

aws cloudwatch put-metric-alarm \
    --alarm-name notes-rds-cpu \
    --namespace AWS/RDS --metric-name CPUUtilization \
    --dimensions Name=DBInstanceIdentifier,Value=notes-db \
    --statistic Average --period 300 \
    --evaluation-periods 3 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --alarm-actions $TOPIC

aws cloudwatch put-metric-alarm \
    --alarm-name notes-alb-unhealthy-hosts \
    --namespace AWS/ApplicationELB \
    --metric-name UnHealthyHostCount \
    --dimensions Name=LoadBalancer,Value=$ALB_DIM Name=TargetGroup,Value=$TG_DIM \
    --statistic Maximum \
    --period 60 \
    --evaluation-periods 1 \
    --threshold 0 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions $TOPIC

aws cloudwatch put-metric-alarm \
    --alarm-name notes-rds-low-storage \
    --namespace AWS/RDS \
    --metric-name FreeStorageSpace \
    --dimensions Name=DBInstanceIdentifier,Value=notes-db \
    --statistic Average \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 5000000000 \
    --comparison-operator LessThanOrEqualToThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions $TOPIC

aws cloudwatch put-metric-alarm \
    --alarm-name notes-rds-high-connections \
    --namespace AWS/RDS \
    --metric-name DatabaseConnections \
    --dimensions Name=DBInstanceIdentifier,Value=notes-db \
    --statistic Average \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 100 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions $TOPIC

aws cloudwatch put-metric-alarm \
    --alarm-name notes-alb-p95-latency \
    --namespace AWS/ApplicationELB \
    --metric-name TargetResponseTime \
    --dimensions Name=LoadBalancer,Value=$ALB_DIM \
    --extended-statistic "p95" \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 1.5 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions $TOPIC

aws cloudwatch put-metric-alarm \
    --alarm-name notes-nat-port-allocation-error \
    --namespace AWS/NATGateway \
    --metric-name ErrorPortAllocation \
    --dimensions Name=NatGatewayId,Value=$NAT_ID \
    --statistic Sum \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 1 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions $TOPIC

# CloudWatch Logs
aws logs create-log-group --log-group-name notes-app --region eu-west-1


aws logs put-retention-policy \
    --log-group-name /aws/rds/instance/notes-db/postgresql \
    --retention-in-days 30 \
    --region eu-west-1


ALB_LOG_GROUP="/aws/elasticloadbalancing/notes-alb"
aws logs create-log-group \
    --log-group-name "$ALB_LOG_GROUP" \
    --region "$AWS_REGION"

aws logs put-retention-policy \
    --log-group-name "$ALB_LOG_GROUP" \
    --retention-in-days 30 \
    --region "$AWS_REGION"

aws logs put-delivery-source \
    --name notes-alb-source \
    --resource-arn "$ALB_ARN" \
    --log-type ACCESS_LOGS \
    --region "$AWS_REGION"

DEST_RESOURCE_ARN="arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$ALB_LOG_GROUP"
aws logs put-delivery-destination \
    --name notes-alb-destination \
    --delivery-destination-configuration destinationResourceArn="$DEST_RESOURCE_ARN" \
    --region "$AWS_REGION"

DEST_FULL_ARN="arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:delivery-destination:notes-alb-destination"
aws logs create-delivery \
    --delivery-source-name notes-alb-source \
    --delivery-destination-arn "$DEST_FULL_ARN" \
    --region "$AWS_REGION"



BUCKET_NAME="${PROJ}-${ACCOUNT_ID}-notes-vpc-flow-logs"
AWS_REGION="eu-west-1"
aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
S3_FLOW_LOGS_ARN="arn:aws:s3:::${BUCKET_NAME}"

cat << EOF > flow-log-bucket-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VPCFlowLogsPublish",
      "Effect": "Allow",
      "Principal": {
        "Service": "vpc-flow-logs.amazonaws.com"
      },
      "Action": "s3:PutObject",
      "Resource": "$S3_FLOW_LOGS_ARN/*"
    }
  ]
}
EOF
aws s3api put-bucket-policy \
    --bucket "$BUCKET_NAME" \
    --policy file://flow-log-bucket-policy.json
rm flow-log-bucket-policy.json

aws ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids $VPC_ID \
    --traffic-type ALL \
    --log-destination-type s3 \
    --log-destination $S3_FLOW_LOGS_ARN \
    --max-aggregation-interval 600


TRAIL_NAME="notes-prod-trail"
BUCKET_NAME_FOR_TRAIL="notes-cloudtrail-logs-${ACCOUNT_ID}"

aws s3api create-bucket \
    --bucket "${BUCKET_NAME_FOR_TRAIL}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}" \
    --versioning-configuration Status=Enabled

KMS_KEY_ARN=$(aws kms create-key \
    --description "KMS key for CloudTrail log encryption" \
    --query "KeyMetadata.Arn" \
    --output text \
    --region "$AWS_REGION")

aws kms create-alias \
    --alias-name "alias/notes-cloudtrail-key" \
    --target-key-id "$KMS_KEY_ARN" \
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
    --key-id "$KMS_KEY_ARN" \
    --policy-name "default" \
    --policy file://kms-policy.json \
    --region "${ACCOUNT_ID}"

rm kms-policy.json

cat << EOF > s3-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudtrail.amazonaws.com"
      },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::${BUCKET_NAME_FOR_TRAIL}"
    },
    {
      "Sid": "AWSCloudTrailWrite",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudtrail.amazonaws.com"
      },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME_FOR_TRAIL}/AWSLogs/${ACCOUNT_ID}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control"
        }
      }
    }
  ]
}
EOF

aws s3api put-bucket-policy \
    --bucket "$BUCKET_NAME_FOR_TRAIL" \
    --policy file://s3-policy.json

rm s3-policy.json

aws cloudtrail create-trail \
    --name "$TRAIL_NAME" \
    --s3-bucket-name "$BUCKET_NAME_FOR_TRAIL" \
    --is-multi-region-trail \
    --enable-log-file-validation \
    --kms-key-id "$KMS_KEY_ARN" \
    --region "$AWS_REGION"

aws cloudtrail start-logging --name "$TRAIL_NAME" --region "$AWS_REGION"