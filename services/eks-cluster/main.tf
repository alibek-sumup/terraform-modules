provider "aws" {
  # The AWS region in which all resources will be created
  region = var.aws_region

  # Require a 2.x version of the AWS provider
  version = ">= 2.49"

  # Only these AWS Account IDs may be operated on by this template
  allowed_account_ids = [var.aws_account_id]
}

terraform {
  # The configuration for this backend will be filled in by Terragrunt or via a backend.hcl file. See
  # https://www.terraform.io/docs/backends/config.html#partial-configuration
  backend "s3" {}

  # Only allow this Terraform version. Note that if you upgrade to a newer version, Terraform won't allow you to use an
  # older version, so when you upgrade, you should upgrade everyone on your team and your CI servers all at once.
  required_version = "= 0.12.29"
}

module "eks_cluster" {
  # Make sure to replace <VERSION> in this URL with the latest terraform-aws-eks release
  source = "git@github.com:gruntwork-io/terraform-aws-eks.git//modules/eks-cluster-control-plane?ref=v0.27.2"

  cluster_name = var.cluster_name

  vpc_id                = data.terraform_remote_state.vpc.outputs.vpc_id
  vpc_master_subnet_ids = data.terraform_remote_state.vpc.outputs.private_app_subnet_ids

  enabled_cluster_log_types = ["api", "audit", "authenticator"]
  kubernetes_version        = 1.10
  endpoint_public_access    = false
}

module "eks_workers" {
  # Make sure to replace <VERSION> in this URL with the latest terraform-aws-eks release
  source = "git@github.com:gruntwork-io/terraform-aws-eks.git//modules/eks-cluster-workers?ref=v0.27.2"

  name_prefix  = "app-workers-"
  cluster_name = var.cluster_name

  vpc_id                = data.terraform_remote_state.vpc.outputs.vpc_id
  vpc_worker_subnet_ids = data.terraform_remote_state.vpc.outputs.private_app_subnet_ids

  eks_master_security_group_id = module.eks_cluster.eks_master_security_group_id

  cluster_min_size = var.cluster_min_size
  cluster_max_size = var.cluster_max_size

  cluster_instance_ami          = var.cluster_instance_ami
  cluster_instance_type         = var.cluster_instance_type
  cluster_instance_keypair_name = var.cluster_instance_keypair_name
  cluster_instance_user_data    = data.template_file.user_data.rendered
}

data "template_file" "user_data" {
  template = file("${path.module}/user-data/user-data.sh")

  vars = {
    aws_region                = var.aws_region
    eks_cluster_name          = var.cluster_name
    eks_endpoint              = module.eks_cluster.eks_cluster_endpoint
    eks_certificate_authority = module.eks_cluster.eks_cluster_certificate_authority
    vpc_name                  = var.vpc_name
    log_group_name            = var.cluster_name
  }
}

module "cloudwatch_log_aggregation" {
  # Make sure to replace <VERSION> in this URL with the latest module-aws-monitoring release
  source = "git@github.com:gruntwork-io/module-aws-monitoring.git//modules/logs/cloudwatch-log-aggregation-iam-policy?ref=v0.23.3"

  name_prefix = var.cluster_name
}

resource "aws_iam_policy_attachment" "attach_cloudwatch_log_aggregation_policy" {
  name       = "attach-cloudwatch-log-aggregation-policy"
  roles      = [module.eks_workers.eks_worker_iam_role_name]
  policy_arn = module.cloudwatch_log_aggregation.cloudwatch_log_aggregation_policy_arn
}

module "cloudwatch_metrics" {
  # Make sure to replace <VERSION> in this URL with the latest module-aws-monitoring release
  source = "git@github.com:gruntwork-io/module-aws-monitoring.git//modules/metrics/cloudwatch-custom-metrics-iam-policy?ref=v0.23.3"

  name_prefix = var.cluster_name
}

resource "aws_iam_policy_attachment" "attach_cloudwatch_metrics_policy" {
  name       = "attach-cloudwatch-metrics-policy"
  roles      = [module.eks_workers.eks_worker_iam_role_name]
  policy_arn = module.cloudwatch_metrics.cloudwatch_metrics_policy_arn
}

module "eks_k8s_role_mapping" {
  # Make sure to replace <VERSION> in this URL with the latest terraform-aws-eks release
  source = "git@github.com:gruntwork-io/terraform-aws-eks.git//modules/eks-k8s-role-mapping?ref=v0.27.2"

  # This will configure the worker nodes' IAM role to have access to the system:node Kubernetes role
  eks_worker_iam_role_arns = [module.eks_workers.eks_worker_iam_role_arn]

  # The IAM role to Kubernetes role mappings are passed in via a variable
  iam_role_to_rbac_group_mappings = var.iam_role_to_rbac_group_mappings

  config_map_labels = {
    eks-cluster = module.eks_cluster.eks_cluster_name
  }
}

provider "kubernetes" {
  version = "1.10"

  load_config_file       = false
  host                   = data.template_file.kubernetes_cluster_endpoint.rendered
  cluster_ca_certificate = base64decode(data.template_file.kubernetes_cluster_ca.rendered)
  token                  = data.aws_eks_cluster_auth.kubernetes_token.token
}

# Workaround for Terraform limitation where you cannot directly set a depends on directive or interpolate from resources
# in the provider config.
# Specifically, Terraform requires all information for the Terraform provider config to be available at plan time,
# meaning there can be no computed resources. We work around this limitation by creating a template_file data source
# that does the computation.
# See https://github.com/hashicorp/terraform/issues/2430 for more details
data "template_file" "kubernetes_cluster_endpoint" {
  template = module.eks_cluster.eks_cluster_endpoint
}

data "template_file" "kubernetes_cluster_ca" {
  template = module.eks_cluster.eks_cluster_certificate_authority
}

data "aws_eks_cluster_auth" "kubernetes_token" {
  name = module.eks_cluster.eks_cluster_name
}
