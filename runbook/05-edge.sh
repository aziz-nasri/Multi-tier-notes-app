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

echo "Fetching infrastructure variables from SSM Parameter Store..."
ACCOUNT_ID=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/account_id" --query "Parameter.Value" --output text)
PROJ=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/proj" --query "Parameter.Value" --output text)
AWS_REGION=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/region" --query "Parameter.Value" --output text)
PUB_A=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/pub_a" --query "Parameter.Value" --output text)
PUB_B=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/pub_b" --query "Parameter.Value" --output text)
ALB_SG=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/alb_sg" --query "Parameter.Value" --output text)
WEB_BUCKET=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/web_bucket" --query "Parameter.Value" --output text)
TG_ARN=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/tg_arn" --query "Parameter.Value" --output text)

# TODO: Uncomment this later when CloudFront is integrated
# CLOUDFRONT_DIST_ID=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/cloudfront_dist_id" --query "Parameter.Value" --output text)

echo "Creating Internet-Facing Application Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer --name notes-alb --type application --scheme internet-facing \
  --subnets $PUB_A $PUB_B --security-groups $ALB_SG --tags Key=Project,Value=$PROJ \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

echo "Modifying ALB attributes (drop invalid headers & enable deletion protection)..."
aws elbv2 modify-load-balancer-attributes --load-balancer-arn $ALB_ARN --attributes \
  Key=routing.http.drop_invalid_header_fields.enabled,Value=true Key=deletion_protection.enabled,Value=true

# TODO: Uncomment this later when CloudFront is integrated
# ORIGIN_SECRET=$(openssl rand -hex 24)

# TODO: Uncomment this later when CloudFront is integrated
# LISTENER_ARN=$(aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTPS --port 443 \
#  --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"403","ContentType":"text/plain","MessageBody":"Forbidden"}}]' \
#  --query 'Listeners[0].ListenerArn' --output text)
# echo "Creating listener routing rule with origin verification header..."
# aws elbv2 create-rule --listener-arn $LISTENER_ARN --priority 10 \
#   --conditions "[{\"Field\":\"http-header\",\"HttpHeaderConfig\":{\"HttpHeaderName\":\"X-Origin-Verify\",\"Values\":[\"$ORIGIN_SECRET\"]}}]" \
#   --actions "[{\"Type\":\"forward\",\"TargetGroupArn\":\"$TG_ARN\"}]"

# TODO: Later when you add HTTPS and CloudFront, you can delete this HTTP listener
echo "Creating HTTP listener on port 80 and forwarding directly to target group..."
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)

# TODO: Uncomment this later when CloudFront and $ORIGIN_SECRET are integrated
# echo "Applying S3 bucket policy for CloudFront OAC..."
# cat > web-policy.json <<EOF
# {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},
#  "Action":"s3:GetObject","Resource":"arn:aws:s3:::$WEB_BUCKET/*",
# "Condition":{"StringEquals":{"AWS:SourceArn":"arn:aws:cloudfront::$ACCOUNT_ID:distribution/$CLOUDFRONT_DIST_ID"}}}]}
# EOF
# aws s3api put-bucket-policy --bucket $WEB_BUCKET --policy file://web-policy.json
# rm web-policy.json

echo "Syncing frontend build artifacts to S3 bucket ($WEB_BUCKET)..."
cd ../app
aws s3 sync dist/ s3://$WEB_BUCKET --delete

# TODO: Uncomment this later when CloudFront and $ORIGIN_SECRET are integrated
#echo "Creating CloudFront cache invalidation..."
# aws cloudfront create-invalidation --distribution-id "$CLOUDFRONT_DIST_ID" --paths "/*"

# Store infrastructure outputs in SSM Parameter Store
save_to_ssm "alb_arn" "$ALB_ARN"

echo "All infrastructure outputs successfully stored in SSM Parameter Store!"