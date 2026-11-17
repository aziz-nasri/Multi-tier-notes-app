#!/bin/bash
set -euo pipefail

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

ACCOUNT_ID=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/account_id" --query "Parameter.Value" --output text)
PROJ=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/proj" --query "Parameter.Value" --output text)
AWS_REGION=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/region" --query "Parameter.Value" --output text)
ALB_ARN=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/alb_arn" --query "Parameter.Value" --output text)
TG_ARN=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/tg_arn" --query "Parameter.Value" --output text)
EMAIL=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/email" --query "Parameter.Value" --output text)
VPC_ID=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/vpc_id" --query "Parameter.Value" --output text)
NAT_ID=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/nat_id" --query "Parameter.Value" --output text)
KMS_KEY_ARN_FOR_CT=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/key_for_cloudtrail" --query "Parameter.Value" --output text)
KMS_KEY_ARN_FOR_BACKUP=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/key_for_backup" --query "Parameter.Value" --output text)


ALB_DIM=$(echo $ALB_ARN | cut -d/ -f2-)
TG_DIM=$(echo $TG_ARN | cut -d/ -f2-)
:<<"LOG"
TOPIC=$(aws sns create-topic --name notes-alerts --query TopicArn --output text)
aws sns subscribe --topic-arn $TOPIC --protocol email --notification-endpoint $EMAIL
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


RDS_LOG_GROUP="/aws/rds/instance/notes-db/postgresql"
aws logs create-log-group \
    --log-group-name "$RDS_LOG_GROUP" \
    --region "$AWS_REGION"

aws logs put-retention-policy \
    --log-group-name $RDS_LOG_GROUP \
    --retention-in-days 30 \
    --region "$AWS_REGION"


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
    --log-type ALB_ACCESS_LOGS \
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
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"

aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME_FOR_TRAIL}" \
    --versioning-configuration Status=Enabled


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
    --kms-key-id "$KMS_KEY_ARN_FOR_CT" \
    --region "$AWS_REGION"

aws cloudtrail start-logging --name "$TRAIL_NAME" --region "$AWS_REGION"


aws backup create-backup-vault --backup-vault-name notes-vault --encryption-key-arn $KMS_KEY_ARN_FOR_BACKUP
BACKUP_PLAN_ID=$(aws backup create-backup-plan --backup-plan '{
  "BackupPlanName": "notes-daily",
  "Rules": [{
    "RuleName": "daily",
    "TargetBackupVaultName": "notes-vault",
    "ScheduleExpression": "cron(0 3 * * ? *)",
    "Lifecycle": {"DeleteAfterDays": 35}
  }]
}' --query "BackupPlanId" --output text)
aws backup create-backup-selection --backup-plan-id $BACKUP_PLAN_ID --backup-selection \
 '{"SelectionName":"tagged","IamRoleArn":"arn:aws:iam::'$ACCOUNT_ID':role/service-role/AWSBackupDefaultServiceRole","ListOfTags":[{"ConditionType":"STRINGEQUALS","ConditionKey":"Backup","ConditionValue":"true"}]}'


 # Budget Alerts
   aws budgets create-budget \
  --account-id "$ACCOUNT_ID" \
  --budget '{"BudgetName":"notes-monthly","BudgetLimit":{"Amount":"100","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"'"$EMAIL"'"}]}]'

   aws ce update-cost-allocation-tags-status \
    --cost-allocation-tags-status '[{"TagKey": "Project", "Status": "Active"}]'

    aws ce get-cost-and-usage \
    --time-period Start=2026-11-01,End=2026-12-01 \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --filter '{"Tags": {"Key": "Project", "Values": ["notesapp"]}}'
LOG
# cost anomaly detection
MONITOR_ARN=$(aws ce create-anomaly-monitor \
    --anomaly-monitor '{
        "MonitorName": "notesapp-cost-monitor",
        "MonitorType": "DIMENSIONAL",
        "MonitorDimension": "TAG",
        "MonitorSpecification": {
            "Tags": {
                "Key": "Project"
            }
        }
    }' \
    --query "MonitorArn" \
    --output text \
    --region "$AWS_REGION")


cat << EOF > subscription.json
{
    "AnomalySubscription": {
        "SubscriptionName": "notesapp-cost-alerts",
        "MonitorArnList": [
            "${MONITOR_ARN}"
        ],
        "Subscribers": [
            {
                "Type": "EMAIL",
                "Address": "${EMAIL}"
            }
        ],
        "Frequency": "DAILY",
        "ThresholdExpression": {
            "Dimensions": {
                "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
                "MatchOptions": [
                    "GREATER_THAN_OR_EQUAL"
                ],
                "Values": [
                    "50"
                ]
            }
        }
    }
}
EOF

aws ce create-anomaly-subscription \
    --cli-input-json file://subscription.json \
    --region "$AWS_REGION"

rm subscription.json