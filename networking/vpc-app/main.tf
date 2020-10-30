provider "aws" {
  # The AWS region in which all resources will be created
  region = var.aws_region

  # Require a 2.x version of the AWS provider
  version = "~> 2.6"

  # Only these AWS Account IDs may be operated on by this template
  allowed_account_ids = [var.aws_account_id]
}

terraform {
  # The configuration for this backend will be filled in by Terragrunt or via a backend.hcl file. See
  # https://www.terraform.io/docs/backends/config.html#partial-configuration
  backend "s3" {}

  # Only allow this Terraform version. Note that if you upgrade to a newer version, Terraform won't allow you to use an
  # older version, so when you upgrade, you should upgrade everyone on your team and your CI servers all at once.
  required_version = "= 0.13.5"
}

module "vpc" {
  # Make sure to replace <VERSION> in this URL with the latest module-vpc release
  source = "git@github.com:gruntwork-io/module-vpc.git//modules/vpc-app?ref=v0.10.2"

  vpc_name         = var.vpc_name
  aws_region       = var.aws_region
  cidr_block       = var.cidr_block
  num_nat_gateways = var.num_nat_gateways
}

module "vpc_network_acls" {
  source = "git@github.com:gruntwork-io/module-vpc.git//modules/vpc-app-network-acls?ref=v0.10.2"

  vpc_id      = module.vpc.vpc_id
  vpc_name    = module.vpc.vpc_name
  vpc_ready   = module.vpc.vpc_ready
  num_subnets = module.vpc.num_availability_zones

  public_subnet_ids              = module.vpc.public_subnet_ids
  private_app_subnet_ids         = module.vpc.private_app_subnet_ids
  private_persistence_subnet_ids = module.vpc.private_persistence_subnet_ids

  public_subnet_cidr_blocks              = module.vpc.public_subnet_cidr_blocks
  private_app_subnet_cidr_blocks         = module.vpc.private_app_subnet_cidr_blocks
  private_persistence_subnet_cidr_blocks = module.vpc.private_persistence_subnet_cidr_blocks
}

data "terraform_remote_state" "mgmt_vpc" {
  backend = "s3"

  config {
    region = var.terraform_state_aws_region
    bucket = var.terraform_state_s3_bucket
    key    = "${var.aws_region}/prod/networking/vpc-mgmt/terraform.tfstate"
  }
}

module "mgmt_vpc_peering_connection" {
  source = "git@github.com:gruntwork-io/module-vpc.git//modules/vpc-peering?ref=v0.10.2"

  # Assume the first listed AWS Account Id is the one that should own the peering connection
  aws_account_id = var.aws_account_id

  origin_vpc_id              = data.terraform_remote_state.mgmt_vpc.outputs.vpc_id
  origin_vpc_name            = data.terraform_remote_state.mgmt_vpc.outputs.vpc_name
  origin_vpc_cidr_block      = data.terraform_remote_state.mgmt_vpc.outputs.vpc_cidr_block
  origin_vpc_route_table_ids = concat(
    data.terraform_remote_state.mgmt_vpc.outputs.private_subnet_route_table_ids,
    [data.terraform_remote_state.mgmt_vpc.outputs.public_subnet_route_table_id]
  )

  # We should be able to compute these numbers automatically, but can't due to a Terraform bug:
  # https://github.com/hashicorp/terraform/issues/3888. Therefore, we make some assumptions: there is one
  # route table per availability zone in private subnets and just one route table in public subnets.
  num_origin_vpc_route_tables = module.vpc.num_availability_zones + 1

  destination_vpc_id              = module.vpc.vpc_id
  destination_vpc_name            = module.vpc.vpc_name
  destination_vpc_cidr_block      = module.vpc.vpc_cidr_block
  destination_vpc_route_table_ids = concat(
    [module.vpc.public_subnet_route_table_id],
    module.vpc.private_app_subnet_route_table_ids,
    module.vpc.private_persistence_route_table_ids,
  )

  # We should be able to compute these numbers automatically, but can't due to a Terraform bug:
  # https://github.com/hashicorp/terraform/issues/3888. Therefore, we make some assumptions: there is one
  # route table per availability zone in private subnets and just one route table in public subnets.
  num_destination_vpc_route_tables = (module.vpc.num_availability_zones * 2) + 1
}

module "vpc_network_acls" {
  source = "git@github.com:gruntwork-io/module-vpc.git//modules/vpc-app-network-acls?ref=v0.10.2"

  # ... (other params omitted) ...

  allow_access_from_mgmt_vpc = true
  mgmt_vpc_cidr_block        = data.terraform_remote_state.mgmt_vpc.vpc_cidr_block
}