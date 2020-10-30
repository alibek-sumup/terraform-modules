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
  source = "git@github.com:gruntwork-io/module-vpc.git//modules/vpc-mgmt?ref=v0.10.2"

  vpc_name         = var.vpc_name
  aws_region       = var.aws_region
  cidr_block       = var.cidr_block
  num_nat_gateways = var.num_nat_gateways
}
module "vpc_network_acls" {
  # Make sure to replace <VERSION> in this URL with the latest module-vpc release
  source = "git@github.com:gruntwork-io/module-vpc.git//modules/vpc-mgmt-network-acls?ref=v0.10.2"

  vpc_id      = module.vpc.vpc_id
  vpc_name    = module.vpc.vpc_name
  vpc_ready   = module.vpc.vpc_ready
  num_subnets = module.vpc.num_availability_zones

  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  public_subnet_cidr_blocks  = module.vpc.public_subnet_cidr_blocks
  private_subnet_cidr_blocks = module.vpc.private_subnet_cidr_blocks
}