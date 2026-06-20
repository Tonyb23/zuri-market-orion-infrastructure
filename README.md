# Zuri Market — Infrastructure

## Architecture Diagram
![Architecture Diagram](https://raw.githubusercontent.com/Tonyb23/zuri-market-orion-frontend/1dcd84f5d1be38099473329429b941b0990ac7bc/zurimarket-architecture.svg)

## 1. Project Overview

This repo provisions the AWS infrastructure that the Zuri Market app runs on, using **Terraform**. It creates a VPC, a public subnet, a single EC2 instance that auto-installs **k3s** (lightweight Kubernetes) on first boot, the security group that controls traffic to it, and the IAM role that lets the instance read application secrets from AWS Secrets Manager. The frontend and backend repos build and push container images; this repo is what gives those images somewhere to run.

## 2. Tech Stack

- **Terraform** `~> 1.0`
- **AWS provider** `~> 5.0` (`hashicorp/aws`)
- **AWS S3** — remote state storage, with versioning, encryption, and state locking (`use_lockfile`) enabled
- **k3s** — installed on the EC2 instance via a `user_data` boot script (not a Terraform resource itself, but provisioned by this code)
- Target OS: **Ubuntu 22.04** (resolved dynamically via an `aws_ami` data source, not pinned to a fixed AMI ID)

## 3. Project Structure

```
zuri-market-orion-infrastructure/
├── bootstrap/
│   └── main.tf          # Phase 1: creates the S3 bucket that stores Terraform's remote state
├── main.tf                # Phase 2: VPC, subnet, IGW, route table, security group, IAM role, EC2 instance
├── variables.tf            # Input variables (region, project name, instance type, key pair name)
├── outputs.tf                # Values printed after apply (public IP, instance ID, SSH command, app URL, VPC ID)
└── .gitignore
```

- **`bootstrap/main.tf`** — A small, standalone Terraform configuration with no remote backend of its own (it can't store its state in a bucket that doesn't exist yet). Run once, before anything else.
- **`main.tf`** — The actual infrastructure: networking, security group, IAM, and the EC2 instance. Configured to store *its* state in the bucket that `bootstrap/` creates.
- **`variables.tf`** — Every configurable input, each with a sensible default.
- **`outputs.tf`** — Everything you need after a successful apply: the instance's public IP, a ready-to-run SSH command, and the URL where the deployed app will be reachable.

## 4. Prerequisites

- An AWS account, with credentials available to Terraform via the standard AWS credential chain (`aws configure`, environment variables, or an assumed role — see [Secrets & Credentials](#9-secrets--credentials))
- Terraform `~> 1.0` installed locally
- An EC2 key pair already created in the target AWS region, with a name matching the `key_pair_name` variable (default: `ubuntu-ec2-key`) — Terraform does not create this for you
- Sufficient AWS permissions to create VPCs, subnets, security groups, IAM roles/policies, EC2 instances, and S3 buckets

## 5. Variables

Defined in `variables.tf`, all with defaults — override them with a `terraform.tfvars` file or `-var` flags if your setup differs.

| Variable | Description | Default |
|---|---|---|
| `aws_region` | AWS region to deploy into | `us-east-1` |
| `project_name` | Prefix used to name and tag every resource | `zurimarket-k3s` |
| `instance_type` | EC2 instance type for the k3s server | `c7i-flex.large` |
| `key_pair_name` | Name of an **existing** AWS key pair used for SSH access | `ubuntu-ec2-key` |

> The comment above `instance_type` in `variables.tf` notes `t2.medium` as the practical minimum size for k3s (2 vCPU / 2 GB RAM) — useful as a lower bound if you choose to override the default.

## 6. Remote State (S3 Backend)

`main.tf` configures an S3 backend so Terraform's state isn't kept only on a local machine:

```hcl
backend "s3" {
  bucket       = "zurimarket-terraform-state-orion"
  key          = "zurimarket/k3s/terraform.tfstate"
  region       = "us-east-1"
  use_lockfile = true   # state locking without a separate DynamoDB table
  encrypt      = true
}
```

That bucket is exactly what `bootstrap/` creates — which is why bootstrap has to run, and succeed, before `main.tf` can be initialized.

## 7. Deployment

Deployment happens in two phases, in order. There is no CI/CD pipeline in this repo (unlike the frontend/backend repos) — both phases are run manually from your machine.

### Phase 0 — Clone the repo

```bash
git clone https://github.com/Tonyb23/zuri-market-orion-infrastructure.git
```

### Phase 1 — Bootstrap (run once, ever)

Creates the S3 bucket that will hold Terraform's remote state for everything else. Skip this if the bucket already exists.

```bash
cd bootstrap
terraform init
terraform plan
terraform apply
```

This configuration has no backend block of its own, so its state stays **local**, in `bootstrap/terraform.tfstate`. Keep that file safe — losing it doesn't delete the bucket, but you'd need to re-`import` it into state rather than just re-running `apply`.

### Phase 2 — Main infrastructure

Provisions the VPC, subnet, security group, IAM role, and the EC2 instance itself.

```bash
cd ..   # back to the repo root
terraform init
terraform plan
terraform apply
```

`terraform init` here connects to the S3 backend created in Phase 1, so it must run after bootstrap has succeeded at least once.

## 8. Outputs

After a successful `apply` in the root module, Terraform prints:

| Output | Description |
|---|---|
| `instance_public_ip` | Public IP address of the EC2 instance |
| `instance_id` | The EC2 instance's ID |
| `ssh_command` | A ready-to-run `ssh -i ...` command to connect to the instance |
| `app_url` | URL where the deployed app becomes reachable once k3s and the app are running (`http://<public_ip>:30080`) |
| `vpc_id` | The ID of the created VPC |

## 9. Secrets & Credentials

This repo never stores or generates any application secrets — its only job is to grant the EC2 instance *permission* to read them at runtime.

- **Terraform's own AWS credentials** come from your local environment (`aws configure`, `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, or an assumed role) when run manually, exactly as described above in [Prerequisites](#4-prerequisites).
- **The IAM role and policy** created in `main.tf` (`aws_iam_role.k3s_role`, attached via an instance profile) grant the EC2 instance `secretsmanager:GetSecretValue` so that, once the app is deployed, the backend's deploy pipeline can pull `API_SECRET_KEY` and `STORE_NAME` from AWS Secrets Manager and inject them as Kubernetes secrets.
- **No `.tfvars`, `.pem`, or state files are committed** — `.gitignore` excludes `*.tfvars`, `*.pem`, and all local/cached Terraform state.

## 10. Destroying Infrastructure

To tear down the main infrastructure (VPC, subnet, security group, IAM role, EC2 instance):

```bash
terraform destroy
```

The S3 state bucket created in `bootstrap/` is intentionally harder to remove: it has `lifecycle { prevent_destroy = true }` set, so a plain `terraform destroy` inside `bootstrap/` will fail. This is deliberate — it protects your Terraform state history from being deleted by accident. Remove the `prevent_destroy` line yourself first if you genuinely need to delete the bucket.
