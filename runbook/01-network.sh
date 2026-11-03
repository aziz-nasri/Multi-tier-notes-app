# VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJ-vpc},{Key=Project,Value=$PROJ}]" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Subnets
mk_subnet(){ aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $1 --availability-zone ${AWS_REGION}$2 \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$3},{Key=Project,Value=$PROJ}]" \
  --query Subnet.SubnetId --output text; }
PUB_A=$(mk_subnet 10.0.0.0/24  a pub-a);  PUB_B=$(mk_subnet 10.0.1.0/24  b pub-b)
APP_A=$(mk_subnet 10.0.10.0/24 a app-a);  APP_B=$(mk_subnet 10.0.11.0/24 b app-b)
DATA_A=$(mk_subnet 10.0.20.0/24 a data-a); DATA_B=$(mk_subnet 10.0.21.0/24 b data-b)

# IGW + public route table
IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
for s in $PUB_A $PUB_B; do aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $s; done

# NAT + app route table
EIP=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_A --allocation-id $EIP --query NatGateway.NatGatewayId --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID
APP_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $APP_RT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID
for s in $APP_A $APP_B; do aws ec2 associate-route-table --route-table-id $APP_RT --subnet-id $s; done

# Data route table
DATA_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
for s in $DATA_A $DATA_B; do aws ec2 associate-route-table --route-table-id $DATA_RT --subnet-id $s; done

# S3 gateway endpoint
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.$AWS_REGION.s3 \
  --route-table-ids $APP_RT