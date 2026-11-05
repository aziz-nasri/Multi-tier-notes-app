ALB_ARN=$(aws elbv2 create-load-balancer --name notes-alb --type application --scheme internet-facing \
  --subnets $PUB_A $PUB_B --security-groups $ALB_SG --tags Key=Project,Value=$PROJ \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 modify-load-balancer-attributes --load-balancer-arn $ALB_ARN --attributes \
  Key=routing.http.drop_invalid_header_fields.enabled,Value=true Key=deletion_protection.enabled,Value=true

ORIGIN_SECRET=$(openssl rand -hex 24)
ALB_CERT=""
LISTENER_ARN=$(aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTPS --port 443 \
  --certificates CertificateArn=$ALB_CERT --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"403","ContentType":"text/plain","MessageBody":"Forbidden"}}]' \
  --query 'Listeners[0].ListenerArn' --output text)
aws elbv2 create-rule --listener-arn $LISTENER_ARN --priority 10 \
  --conditions "[{\"Field\":\"http-header\",\"HttpHeaderConfig\":{\"HttpHeaderName\":\"X-Origin-Verify\",\"Values\":[\"$ORIGIN_SECRET\"]}}]" \
  --actions "[{\"Type\":\"forward\",\"TargetGroupArn\":\"$TG_ARN\"}]"

# Bucket policy for OAC
cat > web-policy.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},
 "Action":"s3:GetObject","Resource":"arn:aws:s3:::$WEB_BUCKET/*",
 "Condition":{"StringEquals":{"AWS:SourceArn":"arn:aws:cloudfront::$ACCOUNT_ID:distribution/<DIST_ID>"}}}]}
EOF
aws s3api put-bucket-policy --bucket $WEB_BUCKET --policy file://web-policy.json