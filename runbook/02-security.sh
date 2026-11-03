# security groups
mk_sg(){ aws ec2 create-security-group --group-name $1 --description "$1" --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJ}]" --query GroupId --output text; }
ALB_SG=$(mk_sg alb-sg); APP_SG=$(mk_sg app-sg); DB_SG=$(mk_sg db-sg)

CF_PL=$(aws ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text)

aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,PrefixListIds=[{PrefixListId=$CF_PL}]"
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$ALB_SG}]"
aws ec2 authorize-security-group-ingress --group-id $DB_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$APP_SG}]"

# Replace default allow-all egress with scoped egress
for sg in $ALB_SG $APP_SG $DB_SG; do
  aws ec2 revoke-security-group-egress --group-id $sg \
    --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]'; done
    
aws ec2 authorize-security-group-egress --group-id $ALB_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$APP_SG}]"
aws ec2 authorize-security-group-egress --group-id $APP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$DB_SG}]" \
                   "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]"