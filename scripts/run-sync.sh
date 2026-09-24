#!/usr/bin/env bash
set -eo pipefail

APP_DIR="/home/ubuntu/cloudquery"
CONFIG_DIR="${APP_DIR}/config/clients"
BASE_CONFIG="${APP_DIR}/config/base.yml"
REPORTS_ROOT="${APP_DIR}/reports"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%H-%M-%S)
LOCK_FILE="/tmp/cloudquery-sync.lock"
CQ_CLI="${APP_DIR}/cache/cloudquery"

# 1. Lock Protection
exec 200>"$LOCK_FILE"
flock -n 200 || { echo -e "\n\033[1;31m[ERROR]\033[0m Another CloudQuery scan is currently running. Please wait."; exit 1; }

# 1b. Verify CLI binary exists
if [ ! -x "$CQ_CLI" ]; then
    echo -e "\033[1;31m[ERROR]\033[0m CloudQuery CLI not found at $CQ_CLI"
    echo "       Build it with: cd ${APP_DIR}/cli && go build -o ${CQ_CLI} ."
    exit 1
fi

# 2. Interactive Client Selection
CLIENT_FILES=($(find "$CONFIG_DIR" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | sort))

if [ ${#CLIENT_FILES[@]} -eq 0 ]; then
    echo -e "\033[1;31m[ERROR]\033[0m No client config files found in $CONFIG_DIR."
    exit 1
fi

if [ -n "$1" ]; then
    CHOSEN_INPUT="$1"
else
    echo "======================================================="
    echo "       CLOUDQUERY AWS CRAWLER & SECURITY AUDIT         "
    echo "======================================================="
    echo "Available Clients / Configurations:"
    for i in "${!CLIENT_FILES[@]}"; do
        FNAME=$(basename "${CLIENT_FILES[$i]}")
        echo "  [$((i+1))] $FNAME"
    done
    echo "  [A] Scan All Clients"
    echo ""
    read -p "Select a client to scan [1-${#CLIENT_FILES[@]} or A]: " CHOSEN_INPUT
fi

# Resolve Target Config
TARGET_FILES=()
CLIENT_NAME=""

if [[ "$CHOSEN_INPUT" =~ ^[Aa]$ || "$CHOSEN_INPUT" == "all" ]]; then
    TARGET_FILES=("${CLIENT_FILES[@]}")
    CLIENT_NAME="all-clients"
elif [[ "$CHOSEN_INPUT" =~ ^[0-9]+$ ]] && [ "$CHOSEN_INPUT" -ge 1 ] && [ "$CHOSEN_INPUT" -le ${#CLIENT_FILES[@]} ]; then
    TARGET_FILES=("${CLIENT_FILES[$((CHOSEN_INPUT-1))]}")
    CLIENT_NAME=$(basename "${TARGET_FILES[0]}" | sed -E 's/\.(ya?ml)$//')
else
    MATCH=$(find "$CONFIG_DIR" -name "${CHOSEN_INPUT}*" | head -n 1)
    if [ -f "$MATCH" ]; then
        TARGET_FILES=("$MATCH")
        CLIENT_NAME=$(basename "$MATCH" | sed -E 's/\.(ya?ml)$//')
    else
        echo -e "\033[1;31m[ERROR]\033[0m Invalid selection: '$CHOSEN_INPUT'"
        exit 1
    fi
fi

REPORT_DIR="${REPORTS_ROOT}/${DATE}/${CLIENT_NAME}"
mkdir -p "$REPORT_DIR" "${APP_DIR}/logs"
SUMMARY_FILE="${REPORT_DIR}/summary.jsonl"
LOG_FILE="${APP_DIR}/logs/sync_${CLIENT_NAME}_${DATE}_${TIMESTAMP}.log"

echo -e "\n\033[1;32m[INFO]\033[0m Starting scan for: \033[1m${CLIENT_NAME}\033[0m"

# 3. Execute CloudQuery Sync (local CLI binary — no login/SaaS needed)
"$CQ_CLI" sync "$BASE_CONFIG" "${TARGET_FILES[@]}" \
  --cq-dir "${APP_DIR}/cache" \
  --no-log-file \
  --log-console \
  --summary-location "$SUMMARY_FILE" 2>&1 | tee "$LOG_FILE"

SYNC_EXIT=${PIPESTATUS[0]}

if [ $SYNC_EXIT -ne 0 ]; then
    echo -e "\n\033[1;31m[ERROR]\033[0m Sync failed with exit code $SYNC_EXIT. Check log: $LOG_FILE"
    exit $SYNC_EXIT
fi

# 4. Extract Inventory Counts from PostgreSQL
echo -e "\n[INFO] Compiling security audit and inventory data..."

EC2_COUNT=$(docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -t -c "SELECT count(*) FROM aws_ec2_instances;" 2>/dev/null || echo "0")
S3_COUNT=$(docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -t -c "SELECT count(*) FROM aws_s3_buckets;" 2>/dev/null || echo "0")
IAM_ROLE_COUNT=$(docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -t -c "SELECT count(*) FROM aws_iam_roles;" 2>/dev/null || echo "0")
RDS_COUNT=$(docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -t -c "SELECT count(*) FROM aws_rds_instances;" 2>/dev/null || echo "0")
VPC_COUNT=$(docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -t -c "SELECT count(*) FROM aws_ec2_vpcs;" 2>/dev/null || echo "0")

UNENCRYPTED_S3=$(docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -t -c "SELECT count(*) FROM aws_s3_buckets WHERE server_side_encryption_configuration IS NULL;" 2>/dev/null || echo "0")
OPEN_SG=$(docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -t -c "SELECT count(DISTINCT group_id) FROM aws_ec2_security_group_ip_permissions WHERE cidr_ipv4 = '0.0.0.0/0' AND (from_port IN (22, 3389, 5432, 3306) OR to_port IN (22, 3389, 5432, 3306));" 2>/dev/null || echo "0")

# 5. Export CSV Finding Files
docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -c "
\copy (SELECT account_id, region, name, creation_date FROM aws_s3_buckets WHERE server_side_encryption_configuration IS NULL) TO STDOUT WITH CSV HEADER" > "${REPORT_DIR}/unencrypted_s3_buckets.csv" 2>/dev/null || true

docker exec -i cq-postgres-engine psql -U cq_admin -d cloudquery -c "
\copy (SELECT account_id, instance_id, instance_type, state_name, private_ip_address FROM aws_ec2_instances) TO STDOUT WITH CSV HEADER" > "${REPORT_DIR}/ec2_inventory.csv" 2>/dev/null || true

# 6. Generate Self-Contained HTML Report
cat <<EOF > "${REPORT_DIR}/audit-report.html"
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>AWS Cloud Audit Report - ${CLIENT_NAME}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin: 40px; background: #f8fafc; color: #1e293b; }
    .card { background: white; padding: 25px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 25px; border: 1px solid #e2e8f0; }
    h1 { color: #0f172a; margin-top: 0; }
    .badge-warn { background: #fef2f2; color: #991b1b; padding: 4px 8px; border-radius: 4px; font-weight: bold; border: 1px solid #fecaca; }
    .badge-ok { background: #f0fdf4; color: #166534; padding: 4px 8px; border-radius: 4px; font-weight: bold; border: 1px solid #bbf7d0; }
    table { width: 100%; border-collapse: collapse; margin-top: 15px; }
    th, td { text-align: left; padding: 12px; border-bottom: 1px solid #e2e8f0; }
    th { background: #f8fafc; font-weight: 600; color: #475569; }
  </style>
</head>
<body>
  <div class="card">
    <h1>🛡️ AWS Cloud Security & Inventory Audit</h1>
    <p><strong>Target:</strong> ${CLIENT_NAME} | <strong>Audit Date:</strong> ${DATE} | <strong>Engine:</strong> CloudQuery CLI</p>
  </div>
  <div class="card">
    <h2>Discovered Cloud Inventory</h2>
    <table>
      <tr><th>Asset Category</th><th>Resource Count</th></tr>
      <tr><td>EC2 Compute Instances</td><td>$(echo $EC2_COUNT | tr -d ' ')</td></tr>
      <tr><td>S3 Storage Buckets</td><td>$(echo $S3_COUNT | tr -d ' ')</td></tr>
      <tr><td>IAM Roles</td><td>$(echo $IAM_ROLE_COUNT | tr -d ' ')</td></tr>
      <tr><td>RDS Databases</td><td>$(echo $RDS_COUNT | tr -d ' ')</td></tr>
      <tr><td>VPC Networks</td><td>$(echo $VPC_COUNT | tr -d ' ')</td></tr>
    </table>
  </div>
  <div class="card">
    <h2>Security Findings</h2>
    <table>
      <tr><th>Security Check</th><th>Status / Findings</th></tr>
      <tr><td>Unencrypted S3 Buckets</td><td><span class="$([ $(echo $UNENCRYPTED_S3 | tr -d ' ') -gt 0 ] && echo 'badge-warn' || echo 'badge-ok')">$(echo $UNENCRYPTED_S3 | tr -d ' ') Buckets</span></td></tr>
      <tr><td>Exposed Security Groups (0.0.0.0/0 on SSH/DB)</td><td><span class="$([ $(echo $OPEN_SG | tr -d ' ') -gt 0 ] && echo 'badge-warn' || echo 'badge-ok')">$(echo $OPEN_SG | tr -d ' ') Groups</span></td></tr>
    </table>
  </div>
</body>
</html>
EOF

# 7. Print Terminal Summary Dashboard
EC2_IP=$(curl -s -m 2 http://checkip.amazonaws.com 2>/dev/null || echo "<YOUR_EC2_IP>")

cat <<EOF

╔═════════════════════════════════════════════════════════════════════════════════╗
║                      EXECUTIVE CLOUD AUDIT REPORT                               ║
╠═════════════════════════════════════════════════════════════════════════════════╣
║ Target: $(printf "%-25s" "${CLIENT_NAME}")     Scan Date: ${DATE} ${TIMESTAMP}               ║
╠═════════════════════════════════════════════════════════════════════════════════╣
║ DISCOVERED ASSETS SUMMARY:                                                      ║
║   • EC2 Compute Instances:        $(printf "%-5s" $(echo $EC2_COUNT | tr -d ' '))                                 ║
║   • S3 Storage Buckets:           $(printf "%-5s" $(echo $S3_COUNT | tr -d ' '))                                 ║
║   • IAM Roles:                    $(printf "%-5s" $(echo $IAM_ROLE_COUNT | tr -d ' '))                                 ║
║   • RDS Databases:                $(printf "%-5s" $(echo $RDS_COUNT | tr -d ' '))                                 ║
║   • VPC Networks:                 $(printf "%-5s" $(echo $VPC_COUNT | tr -d ' '))                                 ║
╠═════════════════════════════════════════════════════════════════════════════════╣
║ SECURITY HIGHLIGHTS:                                                            ║
║   $([ $(echo $UNENCRYPTED_S3 | tr -d ' ') -gt 0 ] && echo "⚠️ " || echo "✅ ") Unencrypted S3 Buckets:      $(printf "%-5s" $(echo $UNENCRYPTED_S3 | tr -d ' '))                                 ║
║   $([ $(echo $OPEN_SG | tr -d ' ') -gt 0 ] && echo "⚠️ " || echo "✅ ") Open Security Groups (SSH/DB):  $(printf "%-5s" $(echo $OPEN_SG | tr -d ' '))                                 ║
╚═════════════════════════════════════════════════════════════════════════════════╝

=======================================================
📥 DOWNLOAD YOUR COMPLETE AUDIT REPORT
=======================================================
Reports generated at: ${REPORT_DIR}
  • audit-report.html          (Styled Executive Report)
  • unencrypted_s3_buckets.csv (CSV finding list)
  • ec2_inventory.csv          (Complete asset list)

Run this command on your laptop's terminal to download:
  scp -i <YOUR_KEY.pem> ubuntu@${EC2_IP}:${REPORT_DIR}/audit-report.html .

