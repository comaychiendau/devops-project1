#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/nginx-user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

dnf install -y nginx

# Ensure Systems Manager is available
if ! systemctl enable --now amazon-ssm-agent; then
    dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
    systemctl enable --now amazon-ssm-agent
fi

cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user nginx;
worker_processes auto;

error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    client_max_body_size 10m;
    server_tokens off;

    resolver 169.254.169.253 valid=30s ipv6=off;

    server {
        listen 80 default_server;
        server_name _;

        location = /nginx-health {
            access_log off;
            default_type text/plain;
            return 200 "healthy\n";
        }

        location / {
            set $backend "java-login-internal-nlb-3ffddacb74ce93ea.elb.ap-southeast-2.amazonaws.com";

            proxy_pass http://$backend:8080;
            proxy_http_version 1.1;

            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Connection "";

            proxy_connect_timeout 10s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;

            proxy_hide_header X-Powered-By;
        }

        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    }
}
NGINXCONF

nginx -t
systemctl enable nginx
systemctl restart nginx