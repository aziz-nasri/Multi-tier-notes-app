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

PROJ=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/proj" --query "Parameter.Value" --output text)
ACCOUNT_ID=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/account_id" --query "Parameter.Value" --output text)
AWS_REGION=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/region" --query "Parameter.Value" --output text)

# VPC
echo "Creating VPC for project $PROJ..."
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJ-vpc},{Key=Project,Value=$PROJ}]" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
echo "VPC created with ID: $VPC_ID"

# Subnets
mk_subnet(){ aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $1 --availability-zone $2 \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$3},{Key=Project,Value=$PROJ}]" \
  --query Subnet.SubnetId --output text; }

echo "Creating public subnets..."
PUB_A=$(mk_subnet 10.0.0.0/24  "${AWS_REGION}a" pub-a);  PUB_B=$(mk_subnet 10.0.1.0/24  "${AWS_REGION}b" pub-b)
echo "Creating app subnets..."
APP_A=$(mk_subnet 10.0.10.0/24 "${AWS_REGION}a" app-a);  APP_B=$(mk_subnet 10.0.11.0/24 "${AWS_REGION}b" app-b)
echo "Creating data subnets..."
DATA_A=$(mk_subnet 10.0.20.0/24 "${AWS_REGION}a" data-a); DATA_B=$(mk_subnet 10.0.21.0/24 "${AWS_REGION}b" data-b)

# IGW + public route table
echo "Setting up Internet Gateway and public route table..."
IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
for s in $PUB_A $PUB_B; do aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $s; done

# NAT + app route table
echo "Allocating Elastic IP and creating NAT Gateway (this may take a moment)..."
EIP=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_A --allocation-id $EIP --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$PROJ-nat},{Key=Project,Value=$PROJ}]" --query NatGateway.NatGatewayId --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID
APP_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $APP_RT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID
for s in $APP_A $APP_B; do aws ec2 associate-route-table --route-table-id $APP_RT --subnet-id $s; done

# Data route table
echo "Setting up data route table..."
DATA_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
for s in $DATA_A $DATA_B; do aws ec2 associate-route-table --route-table-id $DATA_RT --subnet-id $s; done

# S3 gateway endpoint
echo "Creating S3 gateway endpoint..."
AWS_REGION=$(aws ssm get-parameter --name "${PROJECT_PREFIX}/region" --query "Parameter.Value" --output text)
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.$AWS_REGION.s3 \
  --route-table-ids $APP_RT

# Store infrastructure outputs in SSM Parameter Store
save_to_ssm "vpc_id" "$VPC_ID"
save_to_ssm "pub_a" "$PUB_A"
save_to_ssm "pub_b" "$PUB_B"
save_to_ssm "app_a" "$APP_A"
save_to_ssm "app_b" "$APP_B"
save_to_ssm "data_a" "$DATA_A"
save_to_ssm "data_b" "$DATA_B"
save_to_ssm "nat_id" "$NAT_ID"

echo "All infrastructure outputs successfully stored in SSM Parameter Store!"

echo "Script completed successfully!"