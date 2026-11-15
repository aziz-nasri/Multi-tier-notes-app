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
APP_A=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/app_a" --query "Parameter.Value" --output text)
APP_B=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/app_b" --query "Parameter.Value" --output text)
APP_SG=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/app_sg" --query "Parameter.Value" --output text)
DB_HOST=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/db_host" --query "Parameter.Value" --output text)
DB_SECRET_ARN=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/db_secret_arn" --with-decryption --query "Parameter.Value" --output text)
ART_BUCKET=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/art_bucket" --query "Parameter.Value" --output text)
KMS_KEY_FOR_ARTI=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/key_for_arti" --query "Parameter.Value" --output text)
VPC_ID=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/vpc_id" --query "Parameter.Value" --output text)

# Package & upload application code
echo "Packaging application artifacts..."
cd ../app
tar czf api-latest.tgz app.py requirements.txt notesapp.service

echo "Uploading package to S3..."
aws s3 cp api-latest.tgz s3://$ART_BUCKET/api-latest.tgz --sse aws:kms --sse-kms-key-id $KMS_KEY_FOR_ARTI

# User data script for EC2 instances
echo "Generating EC2 user data configuration..."
cat > userdata.sh <<EOF
#!/bin/bash
set -euxo pipefail

dnf install -y python3 python3-pip amazon-cloudwatch-agent
useradd -r -m notes
mkdir -p /opt/notes
cd /opt/notes

aws s3 cp s3://$ART_BUCKET/api-latest.tgz . 
tar xzf api-latest.tgz
curl -sfo rds-ca.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

# Configure CloudWatch Agent
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat << 'CWEOF' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/opt/notes/app.log",
            "log_group_name": "/aws/ec2/notes-app",
            "log_stream_name_prefix": "{instance_id}-",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
    -s

# Setup Python virtual environment
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt

# Generate .env file
cat << ENV > /opt/notes/.env
AWS_REGION=$AWS_REGION
DB_HOST=$DB_HOST
DB_SECRET_ARN=$DB_SECRET_ARN
PORT=3000
ENV

# Install and configure systemd service
mv /opt/notes/notesapp.service /etc/systemd/system/notes.service
systemctl daemon-reload
systemctl enable --now notes
EOF

# Launch template configuration
echo "Creating EC2 Launch Template..."
cat > lt.json <<EOF
{"ImageId":"resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64",
 "InstanceType":"t4g.micro",
 "IamInstanceProfile":{"Name":"notes-ec2-profile"},
 "SecurityGroupIds":["$APP_SG"],
 "MetadataOptions":{"HttpTokens":"required","HttpPutResponseHopLimit":1},
 "BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}],
 "TagSpecifications":[{"ResourceType":"instance","Tags":[{"Key":"Project","Value":"$PROJ"}]}],
 "UserData":"$(base64 -w0 userdata.sh)"}
EOF

aws ec2 create-launch-template --launch-template-name notes-lt --launch-template-data file://lt.json

# Target group + ASG
echo "Creating ALB Target Group and Auto Scaling Group..."
TG_ARN=$(aws elbv2 create-target-group --name notes-tg --protocol HTTP --port 3000 --vpc-id $VPC_ID \
  --target-type instance --health-check-path /api/health --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 --query 'TargetGroups[0].TargetGroupArn' --output text)

save_to_ssm "tg_arn" "$TG_ARN"

aws autoscaling create-auto-scaling-group --auto-scaling-group-name notes-asg \
  --launch-template LaunchTemplateName=notes-lt,Version='$Latest' \
  --min-size 2 --max-size 4 --desired-capacity 2 --vpc-zone-identifier "$APP_A,$APP_B" \
  --target-group-arns $TG_ARN --health-check-type ELB --health-check-grace-period 180 \
  --tags Key=Project,Value=$PROJ,PropagateAtLaunch=true

aws autoscaling put-scaling-policy --auto-scaling-group-name notes-asg --policy-name cpu50 \
  --policy-type TargetTrackingScaling --target-tracking-configuration \
  '{"PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},"TargetValue":50.0}'

rm lt.json
rm userdata.sh
rm api-latest.tgz