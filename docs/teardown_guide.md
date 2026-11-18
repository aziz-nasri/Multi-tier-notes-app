# AWS Infrastructure Teardown Guide

This document outlines all the AWS resources provisioned across your deployment scripts (Monitoring, Auditing, Backups, Cost Governance, Load Balancing, Compute/Auto Scaling, Storage, Database, Networking, Security Groups, IAM, and KMS) and provides the **exact, dependency-safe deletion order** required to manually remove them via the AWS Management Console.

---

## 1. Resource Inventory Summary

| Category | Resource Type | Name / Identifier | Quantity | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Auditing** | **CloudTrail Trail** | `notes-prod-trail` (Multi-region) | 1 | Logs account-wide API activity with KMS encryption and log validation |
| **Monitoring** | **CloudWatch Alarms** | `notes-alb-5xx`, `notes-rds-cpu`, `notes-alb-unhealthy-hosts`, `notes-rds-low-storage`, `notes-rds-high-connections`, `notes-alb-p95-latency`, `notes-nat-port-allocation-error` | 7 | Monitors ALB, RDS, and NAT Gateway health and thresholds |
| **Notifications** | **SNS Topic & Subscription** | `notes-alerts` (Email subscription) | 1 | Delivers CloudWatch alarm notifications via email |
| **Monitoring** | **CloudWatch Log Delivery** | `notes-alb-source` $\rightarrow$ `notes-alb-destination` | 1 | Streams ALB access logs to CloudWatch Logs |
| **Monitoring** | **CloudWatch Log Groups** | `/aws/ec2/notes-app`, `notes-app`, `/aws/rds/instance/notes-db/postgresql`, `/aws/elasticloadbalancing/notes-alb` | 4 | Stores EC2 app logs, RDS PostgreSQL logs, and ALB access logs |
| **Networking** | **VPC Flow Logs** | Flow log attached to `$VPC_ID` | 1 | Captures all VPC network traffic and delivers to S3 |
| **Backups** | **AWS Backup Plan & Vault** | `notes-daily` (selection: `tagged`), `notes-vault` | 1 | Daily automated backups of `Backup=true` resources encrypted via KMS |
| **Cost Governance** | **AWS Budget** | `notes-monthly` ($100 USD limit) | 1 | Alerts at 80% actual spend via email |
| **Cost Governance** | **Cost Anomaly Detection** | Monitor: `notesapp-cost-monitor`, Subscription: `notesapp-cost-alerts` | 1 | Daily alerts for cost anomalies $\ge$ $50 on `Project` tag |
| **Load Balancing** | **Application Load Balancer (ALB)** | `notes-alb` (Internet-facing) | 1 | Entry point across `pub-a` & `pub-b` with `alb-sg` and deletion protection |
| **Load Balancing** | **ALB Listener & Routing Rule** | HTTPS:443 Listener + Priority 10 Rule (`X-Origin-Verify`) | 1 | Terminates TLS and forwards verified CloudFront traffic to `notes-tg` |
| **Load Balancing** | **ALB Target Group** | `notes-tg` (HTTP:3000) | 1 | Routes traffic and runs `/api/health` checks against ASG instances |
| **Compute** | **Auto Scaling Group (ASG)** | `notes-asg` (with `cpu50` scaling policy) | 1 | Manages 2–4 `t4g.micro` EC2 instances across `app-a` and `app-b` |
| **Compute** | **EC2 Launch Template** | `notes-lt` | 1 | Defines AMI, instance profile, `app-sg`, EBS volume, and user data |
| **Storage** | **S3 Buckets** | `$PROJ-$ACCOUNT_ID-web`, `$PROJ-$ACCOUNT_ID-artifacts`, `$PROJ-$ACCOUNT_ID-notes-vpc-flow-logs`, `notes-cloudtrail-logs-$ACCOUNT_ID` | 4 | Stores frontend static files, app artifacts, VPC flow logs, and CloudTrail logs |
| **Database** | **RDS PostgreSQL Instance** | `notes-db` | 1 | Encrypted PostgreSQL database (`db.t4g.micro`) with deletion protection |
| **Database** | **RDS DB Subnet Group** | `notes-db-subnets` | 1 | Groups `data-a` and `data-b` subnets for RDS |
| **Secrets** | **Secrets Manager Secret** | `rds!db-...` (RDS-managed) | 1 | Auto-generated master password secret for `notes-db` |
| **Networking** | **VPC** | `$PROJ-vpc` (`10.0.0.0/16`) | 1 | Isolated virtual private network |
| **Networking** | **Subnets** | `pub-a`, `pub-b`, `app-a`, `app-b`, `data-a`, `data-b` | 6 | Network segments across two Availability Zones |
| **Networking** | **Internet Gateway (IGW)** | Attached to `$VPC_ID` | 1 | Provides internet access to public subnets |
| **Networking** | **Elastic IP (EIP)** | Allocated for NAT Gateway | 1 | Static public IPv4 address |
| **Networking** | **NAT Gateway** | `$NAT_ID` (in `pub-a`) | 1 | Provides outbound internet for private app subnets |
| **Networking** | **Route Tables** | Public, App, and Data custom route tables | 3 | Directs network traffic within the VPC |
| **Networking** | **VPC Endpoint** | `com.amazonaws.<region>.s3` | 1 | Private S3 Gateway Endpoint attached to App RT |
| **Security** | **Security Groups** | `alb-sg`, `app-sg`, `db-sg` | 3 | Tiered firewall rules (CloudFront $\rightarrow$ ALB $\rightarrow$ App $\rightarrow$ DB) |
| **IAM** | **IAM Role & Inline Policy** | `notes-ec2-role` (`notes-app-access`) | 1 | Grants EC2 instances SSM, CloudWatch, Secrets Manager, KMS, and S3 access |
| **IAM** | **Instance Profile** | `notes-ec2-profile` | 1 | Container passing `notes-ec2-role` to EC2 instances |
| **Encryption** | **KMS Customer Managed Keys** | `alias/$PROJ`, `alias/notes-cloudtrail-key`, `alias/notes-backup-key` | 3 | Encryption keys for RDS, Secrets, Artifacts, CloudTrail, and Backup |
| **State** | **SSM Parameters** | `/notesapp/outputs/*` | 20+ | Stores generated resource IDs/ARNs for downstream scripts |

---

## 2. Step-by-Step Deletion Order

> **Important:** Stop logging services (CloudTrail, VPC Flow Logs, and ALB Log Delivery) **before** emptying your S3 buckets and deleting log groups—otherwise, AWS will continue writing new log files into your S3 buckets while you are trying to empty and delete them. Follow these steps in exact numerical order.

### Step 1: Delete CloudTrail Trail (Stop Audit Logging First)
1. Navigate to the **CloudTrail Console** $\rightarrow$ **Trails** in the left navigation pane.
2. Select `notes-prod-trail`.
3. Click **Delete** at the top right, confirm the prompt, and click **Delete**.
   *(Stopping CloudTrail first ensures no new log objects are written to `notes-cloudtrail-logs-$ACCOUNT_ID` while you empty it later).*

### Step 2: Delete VPC Flow Logs
1. Navigate to the **VPC Console** $\rightarrow$ **Your VPCs**.
2. Select your project's VPC (`$PROJ-vpc`).
3. Open the **Flow logs** tab in the bottom details pane.
4. Select the active flow log delivering to `$PROJ-$ACCOUNT_ID-notes-vpc-flow-logs`, click **Actions** $\rightarrow$ **Delete flow logs**, and confirm.

### Step 3: Delete CloudWatch Alarms & SNS Topic
1. Navigate to the **CloudWatch Console** $\rightarrow$ **Alarms** $\rightarrow$ **All alarms**.
2. Select all 7 project alarms:
   * `notes-alb-5xx`
   * `notes-alb-unhealthy-hosts`
   * `notes-alb-p95-latency`
   * `notes-rds-cpu`
   * `notes-rds-low-storage`
   * `notes-rds-high-connections`
   * `notes-nat-port-allocation-error`
3. Click **Actions** $\rightarrow$ **Delete** and confirm.
4. Navigate to the **Simple Notification Service (SNS) Console** $\rightarrow$ **Topics**.
5. Select `notes-alerts`, click **Delete**, type `delete me`, and confirm. *(This also removes the associated email subscription).*

### Step 4: Delete AWS Backup Plan, Recovery Points, and Vault
AWS Backup will not allow you to delete a Backup Vault if a Backup Plan targets it or if any recovery points (backups) exist inside it.
1. Navigate to the **AWS Backup Console** $\rightarrow$ **Backup plans**.
2. Click on `notes-daily`.
3. Under **Resource assignments**, select `tagged`, click **Delete**, and confirm.
4. Once the resource assignment is removed, click **Delete** at the top right of the `notes-daily` plan page, enter `notes-daily`, and confirm.
5. In the left navigation pane, click **Backup vaults** $\rightarrow$ select `notes-vault`.
6. Under **Recovery points**, select any existing backups (e.g., RDS snapshots), click **Actions** $\rightarrow$ **Delete**, and confirm. *(Wait until all recovery points show as deleted).*
7. Click **Delete** at the top right of the `notes-vault` page, enter `notes-vault`, and confirm.

### Step 5: Delete Cost Governance Resources (Budgets & Cost Anomaly Detection)
1. Navigate to the **AWS Billing and Cost Management Console** $\rightarrow$ **Budgets** (left menu).
2. Select `notes-monthly`, click **Actions** $\rightarrow$ **Delete**, and confirm.
3. In the left menu under **Cost Analysis**, select **Cost Anomaly Detection**.
4. Open the **Alert subscriptions** tab $\rightarrow$ select `notesapp-cost-alerts` $\rightarrow$ click **Delete** and confirm.
5. Open the **Cost monitors** tab $\rightarrow$ select `notesapp-cost-monitor` $\rightarrow$ click **Delete** and confirm.
   *(Optional: Under **Cost Allocation Tags**, you can deactivate the `Project` tag if desired, though inactive tags incur no cost).*

### Step 6: Disable Deletion Protection and Delete the Application Load Balancer (ALB)
Your script explicitly enabled `deletion_protection.enabled=true` on `notes-alb`, which must be turned off before AWS allows deletion.
1. Navigate to the **EC2 Console** $\rightarrow$ scroll down the left menu to **Load Balancing** $\rightarrow$ **Load Balancers**.
2. Select `notes-alb`.
3. Click **Actions** $\rightarrow$ **Edit load balancer attributes**.
4. Under **Deletion protection**, select **Disable** and click **Save changes**.
5. With `notes-alb` still selected, click **Actions** $\rightarrow$ **Delete load balancer**, type `confirm`, and click **Delete**.
   *(Note: Deleting the ALB automatically deletes its HTTPS:443 listener, Priority 10 routing rule, and detaches the `notes-alb-source` access log delivery).*

### Step 7: Delete the Auto Scaling Group (Terminates EC2 Instances)
Deleting the Auto Scaling Group automatically removes the `cpu50` target tracking scaling policy and terminates all running EC2 instances (along with their `DeleteOnTermination` EBS volumes).
1. Navigate to the **EC2 Console** $\rightarrow$ **Auto Scaling** $\rightarrow$ **Auto Scaling Groups**.
2. Select `notes-asg`.
3. Click **Delete** at the top right, type `delete`, and click **Delete**.
4. **Wait:** Open **Instances** in the left menu and verify that all EC2 instances tagged with `Project: $PROJ` transition from `Shutting-down` to `Terminated` (1–2 minutes).

### Step 8: Delete the EC2 Launch Template
1. In the **EC2 Console**, select **Instances** $\rightarrow$ **Launch Templates**.
2. Select `notes-lt`.
3. Click **Actions** $\rightarrow$ **Delete template**, type `Delete`, and confirm.

### Step 9: Delete the ALB Target Group
1. In the **EC2 Console**, select **Load Balancing** $\rightarrow$ **Target Groups**.
2. Select `notes-tg`.
3. Click **Actions** $\rightarrow$ **Delete** and confirm.

### Step 10: Empty and Delete All 4 S3 Buckets
Because versioning is enabled on your buckets, standard object deletion only adds delete markers. You must use the **Empty** feature in the console first.
1. Navigate to the **S3 Console**.
2. Locate all **4 buckets** created across your scripts:
   * `$PROJ-$ACCOUNT_ID-web` (frontend static files)
   * `$PROJ-$ACCOUNT_ID-artifacts` (`api-latest.tgz`)
   * `$PROJ-$ACCOUNT_ID-notes-vpc-flow-logs` (VPC flow logs)
   * `notes-cloudtrail-logs-$ACCOUNT_ID` (CloudTrail audit logs)
3. For **each** of the 4 buckets:
   * Select the radio button next to the bucket name and click **Empty**.
   * Type `permanently delete` in the confirmation box and click **Empty** (purges all current objects and historical versions).
   * Return to the **Buckets** list, select the empty bucket, and click **Delete**.
   * Enter the bucket name to confirm and click **Delete bucket**.

### Step 11: Disable Deletion Protection and Delete the RDS Instance
1. Navigate to the **RDS Console** $\rightarrow$ **Databases**.
2. Select `notes-db` and click **Modify**.
3. Scroll down to **Deletion protection**, **uncheck** *Enable deletion protection*, click **Continue** $\rightarrow$ select **Apply immediately** $\rightarrow$ click **Modify DB instance**.
4. Once the modification completes, select `notes-db` and click **Actions** $\rightarrow$ **Delete**.
5. Uncheck *Create final snapshot?*, check the acknowledgment box, type `delete me`, and click **Delete**.
6. **Wait:** Monitor the status until `notes-db` disappears completely (3–5 minutes).
   *(Note: Deleting `notes-db` automatically deletes its RDS-managed master password secret in AWS Secrets Manager).*

### Step 12: Delete the RDS DB Subnet Group
1. In the **RDS Console**, select **Subnet groups**.
2. Select `notes-db-subnets`, click **Delete**, and confirm.

### Step 13: Delete CloudWatch Log Groups & Vended Log Delivery Destinations
1. Navigate to the **CloudWatch Console** $\rightarrow$ **Logs** $\rightarrow$ **Log groups**.
2. Select all **4 log groups** created across your scripts:
   * `/aws/ec2/notes-app`
   * `notes-app`
   * `/aws/rds/instance/notes-db/postgresql`
   * `/aws/elasticloadbalancing/notes-alb`
3. Click **Actions** $\rightarrow$ **Delete log group(s)** and confirm.
4. *(Optional CLI cleanup for vended log delivery metadata)*: If `notes-alb-destination` remains in CloudWatch Logs delivery configurations, it incurs no cost, or can be removed via `aws logs delete-delivery-destination --name notes-alb-destination`.

### Step 14: Delete the VPC Endpoint
1. Navigate to the **VPC Console** $\rightarrow$ **Endpoints**.
2. Select the S3 Gateway Endpoint associated with `$PROJ-vpc`.
3. Click **Actions** $\rightarrow$ **Delete endpoint(s)**, type `delete`, and confirm.

### Step 15: Delete the NAT Gateway
1. In the **VPC Console**, select **NAT gateways**.
2. Select `$NAT_ID`, click **Actions** $\rightarrow$ **Delete NAT gateway**, type `delete`, and confirm.
3. **Wait:** Monitor until its status changes from `Deleting` to `Deleted` (1–2 minutes).

### Step 16: Release the Elastic IP (EIP)
1. In the **VPC Console**, select **Elastic IPs**.
2. Select the Elastic IP address attached to your NAT Gateway, click **Actions** $\rightarrow$ **Release Elastic IP addresses**, and confirm.

### Step 17: Clean Up Security Groups (Rules First, Then Groups)
1. In the **VPC Console**, select **Security groups** and filter by `$VPC_ID`.
2. For each of `alb-sg`, `app-sg`, and `db-sg` (do **not** touch `default`):
   * Open **Inbound rules** $\rightarrow$ **Edit inbound rules** $\rightarrow$ delete all rules $\rightarrow$ **Save rules**.
   * Open **Outbound rules** $\rightarrow$ **Edit outbound rules** $\rightarrow$ delete all rules $\rightarrow$ **Save rules**.
3. Select `alb-sg`, `app-sg`, and `db-sg` together $\rightarrow$ **Actions** $\rightarrow$ **Delete security groups**, type `delete`, and confirm.

### Step 18: Disassociate and Delete Custom Route Tables
1. In the **VPC Console**, select **Route tables**.
2. For each of the **3 custom route tables** (do **not** select `Main: Yes`):
   * Open **Subnet associations** $\rightarrow$ **Edit subnet associations** $\rightarrow$ uncheck all subnets $\rightarrow$ **Save associations**.
   * Click **Actions** $\rightarrow$ **Delete route table** and confirm.

### Step 19: Detach and Delete the Internet Gateway (IGW)
1. In the **VPC Console**, select **Internet gateways**.
2. Select the IGW attached to `$PROJ-vpc` $\rightarrow$ **Actions** $\rightarrow$ **Detach from VPC** $\rightarrow$ confirm.
3. Click **Actions** $\rightarrow$ **Delete internet gateway** and confirm.

### Step 20: Delete All Subnets & the VPC
1. In the **VPC Console**, select **Subnets**, filter by `$VPC_ID`, and select all 6 subnets (`pub-a`, `pub-b`, `app-a`, `app-b`, `data-a`, `data-b`).
2. Click **Actions** $\rightarrow$ **Delete subnet**, type `delete`, and confirm.
3. Navigate to **Your VPCs**, select `$PROJ-vpc`, click **Actions** $\rightarrow$ **Delete VPC**, type `delete`, and confirm.

### Step 21: Delete IAM Role, Inline Policy, and Instance Profile
1. Navigate to the **IAM Console** $\rightarrow$ **Roles**.
2. Search for and select `notes-ec2-role`.
3. Click **Delete**, type `notes-ec2-role`, and confirm. *(Automatically deletes inline policy `notes-app-access` and instance profile `notes-ec2-profile`).*

### Step 22: Schedule KMS Keys for Deletion
1. Navigate to the **Key Management Service (KMS) Console** $\rightarrow$ **Customer managed keys**.
2. For each of the 3 keys (`alias/$PROJ`, `alias/notes-cloudtrail-key`, `alias/notes-backup-key`):
   * Click the **Key ID** $\rightarrow$ **Key actions** $\rightarrow$ **Schedule key deletion**.
   * Set the **Waiting period** to `7` days, check the confirmation box, and click **Schedule deletion**.

### Step 23: Clean Up SSM Parameter Store
1. Navigate to the **Systems Manager Console** $\rightarrow$ **Parameter Store**.
2. Filter by `/notesapp/outputs/` and select all generated output parameters (`alb_arn`, `tg_arn`, `art_bucket`, `web_bucket`, `db_host`, `db_secret_arn`, `vpc_id`, `pub_a`, `pub_b`, `app_a`, `app_b`, `data_a`, `data_b`, `nat_id`, `alb_sg`, `app_sg`, `db_sg`, `key_for_arti`, `key_for_backup`, `key_for_cloudtrail`).
3. Click **Delete** and confirm.