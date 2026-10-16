# One-time setup: the S3 bucket that stores Terraform's state for infra/.
#
# Terraform remembers what it created in a "state" file. Keeping it in S3 (not on a laptop)
# means it survives a lost laptop and teammates can run Terraform too.
#
#   cd infra/bootstrap && terraform init && terraform apply
#
# Then follow the `next_step` output. This folder's own state stays local; it only holds one bucket.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "readtheroom", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  # Bucket names are global across all of AWS, so the account id keeps this one unique.
  bucket = "readtheroom-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # lets you recover an older state file if one gets corrupted
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "next_step" {
  value = <<-EOT
    Create infra/backend.hcl containing:

      bucket       = "${aws_s3_bucket.state.bucket}"
      key          = "readtheroom/terraform.tfstate"
      region       = "${var.region}"
      use_lockfile = true

    then run:  cd .. && terraform init -backend-config=backend.hcl
  EOT
}
