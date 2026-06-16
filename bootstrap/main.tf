# This Terraform configuration file sets up an AWS S3 bucket to store Terraform state files securely. 
# It includes configurations for versioning, server-side encryption, and public access restrictions 
# to ensure the safety and integrity of the state files.
provider "aws" {
  region = "us-east-1"
}

# Creating an S3 bucket to store Terraform state files
resource "aws_s3_bucket" "terraform_state" {
  bucket = "zurimarket-terraform-state-orion" # unique name for the S3 bucket

# lifecycle block to prevent accidental deletion of the S3 bucket
  lifecycle {
    prevent_destroy = true
  }

# adding tags to the S3 bucket for identification
  tags = {
    Name = "Zuri Market Terraform State"
    ManagedBy = "Terraform"
  }
}

# enable versioning for the S3 bucket to keep track of changes to the state files
resource "aws_s3_bucket_versioning" "state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# enable server-side encryption for the S3 bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "state_encryption" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# enable public access block for the S3 bucket to prevent public access to the state files
resource "aws_s3_bucket_public_access_block" "state_public_access_block" {
  bucket = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}