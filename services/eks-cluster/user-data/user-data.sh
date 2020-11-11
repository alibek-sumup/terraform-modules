#!/bin/bash

set -e

# Send the log output from this script to user-data.log, syslog, and the console
# From: https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

function start_fail2ban {
  echo "Starting fail2ban"
  /etc/user-data/configure-fail2ban-cloudwatch/configure-fail2ban-cloudwatch.sh --cloudwatch-namespace Fail2Ban
}

function start_cloudwatch_logs_agent {
  local -r vpc_name="$1"
  local -r log_group_name="$2"

  echo "Starting CloudWatch Logs Agent in VPC $vpc_name"
  /etc/user-data/cloudwatch-log-aggregation/run-cloudwatch-logs-agent.sh \
    --vpc-name "$vpc_name" \
    --log-group-name "$log_group_name"
}

function configure_eks_instance {
  local -r aws_region="$1"
  local -r eks_cluster_name="$2"
  local -r eks_endpoint="$3"
  local -r eks_certificate_authority="$4"
  local -r vpc_name="$5"
  local -r log_group_name="$6"

  start_cloudwatch_logs_agent "$vpc_name" "$log_group_name"
  start_fail2ban

  echo "Running eks bootstrap script to register instance to cluster"
  local -r node_labels="$(map-ec2-tags-to-node-labels)"
  /etc/eks/bootstrap.sh \
    --apiserver-endpoint "$eks_endpoint" \
    --b64-cluster-ca "$eks_certificate_authority" \
    --kubelet-extra-args "--node-labels=\"$node_labels\"" \
    "$eks_cluster_name"

  echo "Locking down the EC2 metadata endpoint so only the root and default users can access it"
  /usr/local/bin/ip-lockdown 169.254.169.254 root ec2-user
}

# These variables are set by Terraform interpolation
configure_eks_instance "${aws_region}" "${eks_cluster_name}" "${eks_endpoint}" "${eks_certificate_authority}" "${vpc_name}" "${log_group_name}"