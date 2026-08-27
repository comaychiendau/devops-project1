#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/java-login-user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

REGION="ap-southeast-2"
ARTIFACT_BUCKET="java-login-artifacts-029422951946-ap-southeast-2"
RDS_ENDPOINT="java-login-mysql.cj8m4ciqo6m6.ap-southeast-2.rds.amazonaws.com"
RDS_SECRET_ARN="arn:aws:secretsmanager:ap-southeast-2:029422951946:secret:rds!db-b0e51d95-8134-4662-b18b-a897f185f03a-OjcnNs"

dnf install -y java-21-amazon-corretto-headless jq

# Ensure AWS Systems Manager is running
if ! systemctl enable --now amazon-ssm-agent; then
    dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
    systemctl enable --now amazon-ssm-agent
fi

# Create a dedicated application user
if ! id javaapp >/dev/null 2>&1; then
    useradd --system --home-dir /opt/java-login --shell /sbin/nologin javaapp
fi

install -d -o javaapp -g javaapp -m 0750 /opt/java-login

# Download the WAR using the EC2 IAM role
aws s3 cp \
    "s3://${ARTIFACT_BUCKET}/java-login-app/app.war" \
    /opt/java-login/app.war \
    --region "${REGION}"

chown javaapp:javaapp /opt/java-login/app.war
chmod 0640 /opt/java-login/app.war

# Store only non-secret configuration
cat > /etc/java-login-app.conf <<EOF
REGION="${REGION}"
RDS_ENDPOINT="${RDS_ENDPOINT}"
RDS_SECRET_ARN="${RDS_SECRET_ARN}"
EOF

chown root:javaapp /etc/java-login-app.conf
chmod 0640 /etc/java-login-app.conf

# Retrieve the database password whenever the service starts
cat > /opt/java-login/start.sh <<'STARTSCRIPT'
#!/bin/bash
set -euo pipefail

source /etc/java-login-app.conf

SECRET_JSON="$(/usr/bin/aws secretsmanager get-secret-value \
    --secret-id "${RDS_SECRET_ARN}" \
    --region "${REGION}" \
    --query SecretString \
    --output text)"

DB_USERNAME="$(printf '%s' "${SECRET_JSON}" | /usr/bin/jq -r '.username')"
DB_PASSWORD="$(printf '%s' "${SECRET_JSON}" | /usr/bin/jq -r '.password')"

if [[ "${DB_USERNAME}" == "null" || "${DB_PASSWORD}" == "null" ]]; then
    echo "RDS username or password is missing"
    exit 1
fi

export SPRING_DATASOURCE_URL="jdbc:mysql://${RDS_ENDPOINT}:3306/javaapp?sslMode=REQUIRED&serverTimezone=UTC"
export SPRING_DATASOURCE_USERNAME="${DB_USERNAME}"
export SPRING_DATASOURCE_PASSWORD="${DB_PASSWORD}"
export SPRING_JPA_HIBERNATE_DDL_AUTO="update"
export SPRING_JPA_OPEN_IN_VIEW="false"
export SERVER_PORT="8080"

exec /usr/bin/java -Xms256m -Xmx512m -jar /opt/java-login/app.war
STARTSCRIPT

chown root:javaapp /opt/java-login/start.sh
chmod 0750 /opt/java-login/start.sh

# Run the application as a managed service
cat > /etc/systemd/system/java-login-app.service <<'SERVICE'
[Unit]
Description=Java Login Application with Embedded Tomcat
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=javaapp
Group=javaapp
WorkingDirectory=/opt/java-login
Environment=HOME=/opt/java-login
ExecStart=/opt/java-login/start.sh
Restart=always
RestartSec=10
SuccessExitStatus=143
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now java-login-app