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
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt

DB_HOST=\$(aws rds describe-db-instances --db-instance-identifier notes-db --query 'DBInstances[0].Endpoint.Address' --output text --region $AWS_REGION)
DB_SECRET_ARN=\$(aws rds describe-db-instances --db-instance-identifier notes-db --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text --region $AWS_REGION)

cat << 'ENVEOF' > /opt/notes/.env
AWS_REGION=$AWS_REGION
DB_HOST=\$DB_HOST
DB_SECRET_ARN=\$DB_SECRET_ARN
PORT=3000
ENVEOF

cat > /etc/systemd/system/notes.service << 'UNIT'
[Unit]
Description=Notes API (Python Flask)
After=network-online.target

[Service]
User=notes
WorkingDirectory=/opt/notes
EnvironmentFile=/opt/notes/.env
ExecStart=/opt/notes/venv/bin/gunicorn --workers 3 --bind 0.0.0.0:3000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload && systemctl enable --now notes