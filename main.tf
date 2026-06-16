terraform {
    required_version = "~> 1.0"

# The AWS provider is the plugin that lets Terraform talk to AWS.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

# Configuring the backend to use S3 for storing Terraform state files
  backend "s3" {
    bucket         = "zurimarket-terraform-state-orion"
    key            = "zurimarket/k3s/terraform.tfstate"
    region         = "us-east-1"
    use_lockfile   = true # Enable state locking to prevent concurrent modifications/ replaces dynamoDB tablelocking
    encrypt        = true
  }
}

# Configuring the AWS provider with the specified region
provider "aws" {
  region = var.aws_region
}

# Virtual Private Cloud (VPC) configuration
resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"
    enable_dns_hostnames = true
    enable_dns_support = true
    tags = {
        Name = "${var.project_name}-vpc"
        ManagedBy = "Terraform"
    }
}

# Subnet configuration within the VPC
resource "aws_subnet" "main" {
    vpc_id = aws_vpc.main.id
    cidr_block = "10.0.1.0/24" 
    availability_zone = "${var.aws_region}a" 
    map_public_ip_on_launch = true
    tags = {
        Name = "${var.project_name}-subnet"
        ManagedBy = "Terraform"
    }
}

# Internet Gateway configuration to allow internet access for resources in the VPC
resource "aws_internet_gateway" "main" {
    vpc_id = aws_vpc.main.id
    tags = {
        Name = "${var.project_name}-igw"
        ManagedBy = "Terraform"
    }
}

# Route Table configuration to define routing rules for the VPC
resource "aws_route_table" "main" {
    vpc_id = aws_vpc.main.id
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.main.id
    }
    tags = {
        Name = "${var.project_name}-rt"
        ManagedBy = "Terraform"
    }
}

# Route Table Association to link the route table with the subnet
resource "aws_route_table_association" "main" {
    subnet_id	= aws_subnet.main.id 
    route_table_id = aws_route_table.main.id
}


# IAM role for EC2 to read from Secrets Manager
resource "aws_iam_role" "k3s_role" {
  name = "${var.project_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# IAM policy to allow EC2 instance to read secrets from Secrets Manager
resource "aws_iam_role_policy" "secrets_policy" {
  name = "${var.project_name}-secrets-policy"
  role = aws_iam_role.k3s_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = "*"
    }]
  })
}

# IAM instance profile to attach the role to the EC2 instance
resource "aws_iam_instance_profile" "k3s_profile" {
  name = "${var.project_name}-profile"
  role = aws_iam_role.k3s_role.name
}

# Security group — allow SSH, HTTP, k3s API, and NodePort range
resource "aws_security_group" "k3s_sg" {
    name	= "${var.project_name}-sg" 
    description = "Security group for K3s server" 
    vpc_id	= aws_vpc.main.id

    # Allow SSH from anywhere so we can connect to the server 
    ingress {
        description = "SSH" 
        from_port = 22
        to_port = 22
        protocol = "tcp" 
        cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow HTTP traffic
    ingress {
        description = "HTTP" 
        from_port = 80
        to_port	= 80
        protocol= "tcp" 
        cidr_blocks = ["0.0.0.0/0"]
    }

    # K3s API server — needed for kubectl and GitHub Actions 
    ingress {
        description = "K3s API" 
        from_port = 6443
        to_port	= 6443
        protocol= "tcp" 
        cidr_blocks = ["0.0.0.0/0"]
    }

    # NodePort range — for accessing apps deployed to K3s 
    ingress {
        description = "NodePort range" 
        from_port = 30000
        to_port	= 32767
        protocol= "tcp" 
        cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow all outbound traffic so the server can download updates, etc.
    egress {
        description = "All outbound traffic" 
        from_port = 0
        to_port	= 0
        protocol= "-1" 
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Name = "${var.project_name}-sg"
        ManagedBy = "Terraform"
    }
}

data "aws_ami" "ubuntu" {
    most_recent = true
    owners = ["099720109477"]
    filter {
        name   = "name"
        values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
    }
    filter {
        name   = "virtualization-type"
        values = ["hvm"]
    }
}
# EC2 instance with k3s auto-installed
resource "aws_instance" "k3s-server" {
    ami = data.aws_ami.ubuntu.id
    instance_type = var.instance_type
    subnet_id = aws_subnet.main.id
    vpc_security_group_ids = [aws_security_group.k3s_sg.id]
    associate_public_ip_address = true
    key_name = var.key_pair_name

    # This script runs on first boot — installs K3s automatically.
    # <<-EOF ... EOF is a multi-line string in Terraform (heredoc syntax). 

    user_data = <<-EOF
      #!/bin/bash
      set -euo pipefail

      # Update package lists
      apt-get update -y
      
      # Install curl (Needed to download K3s install script)
      apt-get install -y curl

      # Install K3s using the official install script, installs and starts the service
      curl -sfL https://get.k3s.io | sh -
      
      # Make the kubeconfig readable by the ubuntu user (not just root)
      chmod 644 /etc/rancher/k3s/k3s.yaml
      
      # Add KUBECONFIG to ubuntu user profile so kubectl works on login
      echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /home/ubuntu/.bashrc
    EOF

    # Give the instance a larger root volume so we have space for K3s and any apps we deploy.
    root_block_device {
        volume_size = 8
        volume_type = "gp3"
    }

    tags = {
        Name = "${var.project_name}-server"
        ManagedBy = "Terraform"
    }
}