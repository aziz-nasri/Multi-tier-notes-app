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

