# ── AWS Region ─────────────────────────────────────────────── 
variable "aws_region" {
    description = "AWS region to deploy resources into"
    type = string
    default = "us-east-1"
}

# ── Project Name ─────────────────────────────────────────────── 
variable "project_name" {
    description = "Name of the Project - Prefix for all resources for identification"
    type = string
    default = "zurimarket-k3s"
}


# ── Instance Type ─────────────────────────────────────────────── 
# t2.medium is the minimum for K3s (needs 2 vCPU and 2 GB RAM). 
variable "instance_type" {
    description = "EC2 instance Type"
    type = string
    default = "c7i-flex.large"
}

# ── Key Pair Name ──────────────────────────────────────────── 
# The name of the AWS key pair to use for SSH access.
# This must match the key pair you must have created in the AWS region you are deploying to. 

variable "key_pair_name" {
    description = "Name of the AWS EC2Key Pair for SSH access"
    type = string
    default = "ubuntu-ec2-key" 
}