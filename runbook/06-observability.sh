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

