# CloudQuery AWS Crawler & Security Audit Engine

A production-grade, self-hosted, 100% open-source cloud security auditing tool that discovers AWS assets, detects security misconfigurations, and generates executive HTML dashboards with actionable CSV exports.

---

## 🚀 Quick Start (Running on This EC2 Instance)

### 1. Interactive Scan
Simply run from anywhere:
```bash
cloudquery-scan
```
Menu options:
* `[1] 00-test-mock.yml` — Runs an offline local mock pipeline test (no AWS required).
* `[2] 01-aws-internal.yml` — Audits this server's own AWS account (all enabled regions).
* `[3] client-alpha.yml` — Cross-account audit of an external client's AWS account.
* `[A] Scan All Clients` — Runs batch scans across all configured client profiles.
* `[D] Download / View Past Reports` — Browse and package previously generated audit reports into a single ZIP for easy download.

### 2. Non-Interactive / Automated Scans (Cron)
```bash
cloudquery-scan 1               # Run offline test mock
cloudquery-scan 2               # Audit internal AWS account
cloudquery-scan 01-aws-internal # Audit by filename
cloudquery-scan all             # Audit all client accounts
```

To schedule a daily automated audit at 2:00 AM, add to `crontab -e`:
```bash
0 2 * * * /usr/local/bin/cloudquery-scan 2 > /dev/null 2>&1
```

---

## 📥 Downloading Audit Reports to Your Laptop

Audit reports are generated under `reports/<YYYY-MM-DD>/<CLIENT_NAME>/`.

To download the **complete audit bundle** (HTML dashboard + all CSV finding lists):
```bash
scp -i <YOUR_KEY.pem> -r ubuntu@13.200.216.63:/home/ubuntu/cloudquery/reports/$(date +%Y-%m-%d)/01-aws-internal ./
```

### Generated Report Deliverables:
* `audit-report.html` — Clean, executive visual dashboard with inventory counts and risk badges.
* `open_security_groups.csv` — Security groups exposing dangerous ports (22, 3389, 5432, 3306) to `0.0.0.0/0`.
* `unencrypted_s3_buckets.csv` — S3 buckets missing Server-Side Encryption (SSE).
* `ec2_inventory.csv` — Complete list of EC2 compute instances, types, states, and private IPs.
* `rds_inventory.csv` — Complete list of RDS database instances and engines.
* `iam_roles.csv` — Complete list of IAM roles and creation dates.

---

## 💻 Running Locally in the Future (Workstation / Laptop)

This setup is built with **100% dynamic paths** and **self-healing auto-downloaders**, meaning you can move it to your laptop without modifying code.

### Step 1: Clone or Copy the Repository
```bash
git clone <YOUR_GIT_REPO> cloudquery
cd cloudquery
```

### Step 2: Start PostgreSQL Database
```bash
docker compose up -d
```
*(Runs Postgres 16 on `127.0.0.1:5435` with health checks).*

### Step 3: Configure AWS Credentials (Local Machine)
Since your local laptop does not have an EC2 Instance Profile, choose either:
* **Option A (Standard AWS CLI)**: Run `aws configure` (or `aws sso login`). CloudQuery automatically reads `~/.aws/credentials`.
* **Option B (In `.env`)**: Uncomment and set your keys in `.env`:
  ```bash
  AWS_ACCESS_KEY_ID=AKIA...
  AWS_SECRET_ACCESS_KEY=...
  AWS_DEFAULT_REGION=ap-south-1
  ```

### Step 4: Run the Audit
```bash
./scripts/run-sync.sh
```
*(If the local AWS plugin binary is missing, the script will automatically detect your OS/CPU and download the open-source v22.19.2 binary directly).*

### Step 5: View the Report
Since you are on your local machine, **no `scp` is needed**:
* **macOS:** `open reports/2026-09-25/.../audit-report.html`
* **Linux:** `xdg-open reports/2026-09-25/.../audit-report.html`
* **Windows (WSL2):** `explorer.exe .`

---

## 🏢 Cross-Account Client Audits (Executing Client IAM Roles via ARN)

To audit a client's AWS infrastructure (or multiple client accounts), CloudQuery uses **AWS Security Token Service (STS) `AssumeRole`**:

### How It Works Under the Hood:
1. **Scanner Base Identity**: 
   * **On Local Laptop:** Your base AWS credentials (via `aws configure` or `.env` `AWS_ACCESS_KEY_ID`).
   * **On EC2:** The EC2 Instance Profile attached to your scanner instance.
2. **Target Client Identity**:
   * The client creates an IAM Role in their AWS account (e.g. `arn:aws:iam::123456789012:role/CloudQueryAuditRole`).
3. **STS AssumeRole Handshake**:
   * CloudQuery takes your base credentials and calls AWS STS to assume the client's role using their ARN and `external_id`.
   * STS verifies the client's trust policy and returns temporary 1-hour credentials.
   * CloudQuery crawls all assets in the client account and writes them directly into PostgreSQL.

---

### Step-by-Step Production Setup for Client Accounts

#### Step 1: Give This Trust Policy to the Client's AWS Admin
The client creates an IAM role named `CloudQueryAuditRole` with this **Trust Relationship**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAuditorToAssumeRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<YOUR_AUDITOR_ACCOUNT_ID>:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "company-client-unique-secret-key"
        }
      }
    }
  ]
}
```
> [!IMPORTANT]
> Always enforce `sts:ExternalId` in client trust policies. This protects both you and the client against the AWS "Confused Deputy" vulnerability.

#### Step 2: Permissions Policy on Client Role
Attach the official AWS Managed Policy:
* **`arn:aws:iam::aws:policy/SecurityAudit`**

#### Step 3: Create the Client Config in Your Scanner
Create `config/clients/client-<client-name>.yml`:
```yaml
kind: source
spec:
  name: aws-client-<name>
  path: "${CQ_CACHE_DIR}/cq-source-aws"
  registry: local
  tables: ["*"]
  skip_tables:
    - "aws_cloudtrail_events"
    - "aws_s3_bucket_objects"
  destinations: ["postgresql"]
  spec:
    regions: ["*"] # Or specify e.g. ["ap-south-1", "us-east-1"]
    accounts:
      - id: "<CLIENT_12_DIGIT_ACCOUNT_ID>"
        role_arn: "arn:aws:iam::<CLIENT_12_DIGIT_ACCOUNT_ID>:role/CloudQueryAuditRole"
        external_id: "company-client-unique-secret-key"
        role_session_name: "AuditScan-<name>"
```

#### Step 4: Run the Audit
Run `cloudquery-scan` and your new client will automatically appear in the interactive menu!

---

## 📥 Downloading Reports Without a PEM File

When running scans on the remote EC2 server, you have two ways to get reports onto your laptop:

### Method 1: 1-Click Browser Download Link (No PEM / No SSH Required!)
When bundling a report (or selecting `[D]` for past reports), select **Option 2 (Web Download)**:
* It temporarily starts a lightweight Python download server on port 8080.
* Open the displayed link in your laptop's browser:
  `http://13.200.216.63:8080/audit-bundle-....zip`
* Click to download the ZIP file directly.
* Press Enter in your terminal to shut down the web server when done.

### Method 2: SCP Command (For users with SSH access)
```bash
# With PEM key:
scp -i <YOUR_KEY.pem> ubuntu@13.200.216.63:/home/ubuntu/cloudquery/reports/<DATE>/<CLIENT>/audit-bundle-...zip ./

# Without PEM key (Password or default ~/.ssh key):
scp ubuntu@13.200.216.63:/home/ubuntu/cloudquery/reports/<DATE>/<CLIENT>/audit-bundle-...zip ./
```

---

## 🗄️ Querying the Database Directly

All crawled AWS data is preserved in PostgreSQL on port `5435`:
```bash
docker exec -it cq-postgres-engine psql -U cq_admin -d cloudquery
```

Example queries:
```sql
-- View all discovered tables
\dt aws_*

-- List unencrypted S3 buckets
SELECT account_id, region, name FROM aws_s3_buckets WHERE server_side_encryption_configuration IS NULL;

-- List EC2 instances running
SELECT instance_id, instance_type, state_name FROM aws_ec2_instances WHERE state_name = 'running';
```
