# Package & upload (ensure requirements.txt includes flask, boto3, psycopg2-binary, gunicorn)
tar czf api-latest.tgz app.py requirements.txt notesapp.service
aws s3 cp api-latest.tgz s3://$ART_BUCKET/api-latest.tgz --sse aws:kms --sse-kms-key-id $KMS_KEY

# User data
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
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt

DB_HOST=\$(aws rds describe-db-instances --db-instance-identifier notes-db --query 'DBInstances[0].Endpoint.Address' --output text --region $AWS_REGION)
DB_SECRET_ARN=\$(aws rds describe-db-instances --db-instance-identifier notes-db --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text --region $AWS_REGION)
EOF

cat << 'ENV' > /opt/notes/.env
AWS_REGION=$AWS_REGION
DB_HOST=\$DB_HOST
DB_SECRET_ARN=\$DB_SECRET_ARN
PORT=3000
ENV

cat > /etc/systemd/system/notes.service << 'UNIT'
[Unit]
Description=Notes API (Python Flask)
After=network-online.target

[Service]
User=notes
WorkingDirectory=/opt/notes
EnvironmentFile=/opt/notes/.env
ExecStart=/opt/notes/venv/bin/gunicorn --workers 3 --bind 0.0.0.0:3000 [Service]
ExecStart=/opt/notes/venv/bin/gunicorn --workers 3 --bind 0.0.0.0:3000 --access-logfile /opt/notes/app.log --error-logfile /opt/notes/app.log app:app
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload && systemctl enable --now notes

# Launch template (IMDSv2 enforced, encrypted EBS)
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
TG_ARN=$(aws elbv2 create-target-group --name notes-tg --protocol HTTP --port 3000 --vpc-id $VPC_ID \
  --target-type instance --health-check-path /api/health --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 --query 'TargetGroups[0].TargetGroupArn' --output text)
aws autoscaling create-auto-scaling-group --auto-scaling-group-name notes-asg \
  --launch-template LaunchTemplateName=notes-lt,Version='$Latest' \
  --min-size 2 --max-size 4 --desired-capacity 2 --vpc-zone-identifier "$APP_A,$APP_B" \
  --target-group-arns $TG_ARN --health-check-type ELB --health-check-grace-period 180 \
  --tags Key=Project,Value=$PROJ,PropagateAtLaunch=true
aws autoscaling put-scaling-policy --auto-scaling-group-name notes-asg --policy-name cpu50 \
  --policy-type TargetTrackingScaling --target-tracking-configuration \
  '{"PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},"TargetValue":50.0}'

  # exporting variables
  export TG_ARN