# Zuri Market — Infrastructure

## 1. Project Overview

This repo provisions the AWS infrastructure that the Zuri Market app runs on, using **Terraform**. It creates a VPC, a public subnet, a single EC2 instance that auto-installs **k3s** (lightweight Kubernetes) on first boot, the security group that controls traffic to it, and the IAM role that lets the instance read application secrets from AWS Secrets Manager. The frontend and backend repos build and push container images; this repo is what gives those images somewhere to run.

## Related Repositories

**[Zuri Market - Frontend](https://github.com/Tonyb23/zuri-market-orion-frontend)**  
**[Zuri Market - Backend](https://github.com/Tonyb23/zuri-market-orion-backend)**

## Architecture Diagram
![Architecture Diagram](https://raw.githubusercontent.com/Tonyb23/zuri-market-orion-frontend/1dcd84f5d1be38099473329429b941b0990ac7bc/zurimarket-architecture.svg)

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
├── main.tf                # Phase 2: Core infrastructure resources - VPC, subnet, IGW, route table, security groups, IAM role, EC2 instance
├── variables.tf            # Input variables (region, project name, instance type, key pair name)
├── outputs.tf                # Values printed after terraform apply (public IP, instance ID, SSH command, app URL, VPC ID)
└── .gitignore
```

### Component Reference

- **`bootstrap/main.tf`** — A small, standalone Terraform configuration with no remote backend of its own (it can't store its state in a bucket that doesn't exist yet). Run once, before anything else.
- **`main.tf`** — The actual infrastructure: networking, security group, IAM, and the EC2 instance. Configured to store *its* state in the bucket that `bootstrap/` creates.
- **`variables.tf`** — Every configurable input, each with a sensible default.
- **`outputs.tf`** — Everything you need after a successful apply: the instance's public IP, a ready-to-run SSH command, and the URL where the deployed app will be reachable.

## 4. Prerequisites

- An AWS account, with credentials available to Terraform via the standard AWS credential chain (`aws configure`, environment variables, or an assumed role — see [Secrets & Credentials](#9-secrets--credentials), verify your credentials are working with `aws sts get-caller-identity`)
- Terraform `~> 1.0` installed locally
- An EC2 SSH key pair already created in the target AWS region, with a name matching the `key_pair_name` variable (default: `ubuntu-ec2-key`) — you can download and save this file for SSH access into EC2
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
# Clone the repo or create your own bare clone for more flexibility
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

Provisions the VPC, subnet, IGW, route table, security groups, IAM role, and the EC2 instance itself.

```bash
cd ..   # back to the repo root
terraform init
terraform plan
terraform apply
```

`terraform init` here connects to the S3 backend created in Phase 1, so it must run after bootstrap has succeeded at least once.

### Outputs

After a successful `apply` in the root module, Terraform prints:

| Output | Description |
|---|---|
| `instance_public_ip` | Public IP address of the EC2 instance |
| `instance_id` | The EC2 instance's ID |
| `ssh_command` | A ready-to-run `ssh -i ...` command to connect to the instance |
| `app_url` | URL where the deployed app becomes reachable once k3s and the app are running (`http://<public_ip>:30080`) |
| `vpc_id` | The ID of the created VPC |


### Phase 4 — Connect to EC2, Verify K3s and configure KUBECONFIG

```bash
# SSH into EC2
ssh -i "path-to-your-ssh-key.pem" ubuntu@YOUR_EC2_PUBLIC_IP

# Check k3s is running, it was installed by terraform in the user-date script
kubectl get nodes
```

You might have to reinstall k3s using the EC2 public IP as a SAN (Subject Alternative name) as this was setup using the private IP and would cause your pipeline to fail when it tries to connect to the EC2 instance using this. 

> Another better way to do this is by using an elastic IP so it’s added during provisioning by terraform so your IP remains the same and you don't need to always reconfigure this and your GitHub Actions secrets

```bash
# Stop K3s
sudo systemctl stop k3s

# Remove the old TLS certificates so it gets regenerated
sudo rm -rf /var/lib/rancher/k3s/server/tls/

# reinstall k3s with your EC2 public IP as a SAN
curl -sfL https://get.k3s.io | sh -s - --tls-san YOUR_EC2_PUBLIC_IP

# K3s will regenerate certificates with the new SAN

# Make the kubeconfig readable by the ubuntu user (not just root)
chmod 644 /etc/rancher/k3s/k3s.yaml

# Check k3s is now running again
kubectl get nodes
```

Retrieve KUBECONFIG

```bash
# replace 127.0.0.1 with your EC2 public IP address
sed "s/127.0.0.1/YOUR_EC2_PUBLIC_IP/g" /etc/rancher/k3s/k3s.yaml 

# Copy the output into your GitHub Actions Secret KUBECONFIG
```

### Phase 5 — Store application secrets in AWS Secrets Manager

You can either create this directly on AWS Console or from your local terminal. The pipeline reads from these secrets on every deploy but does not create them — they must exist before the first pipeline run.

```bash
aws secretsmanager create-secret \
  --name zurimarket/api-secret-key \
  --secret-string '{"API_SECRET_KEY":"your-real-prod-secret-key"}' \
  --region us-east-1

aws secretsmanager create-secret \
  --name zurimarket/store-name \
  --secret-string '{"STORE_NAME":"Your-store-name"}' \
  --region us-east-1
```

> Use a strong, unique value for `API_SECRET_KEY` in production — not the dev placeholder from your .env file. These values never appear in Git, GitHub Secrets, Kubernetes manifest files, or Docker images. You can also choose to encode it if you want

Once this is done you can then proceed with the deployment of the Frontend and Backend Deployments

See [Zuri Market - Frontend](https://github.com/Tonyb23/zuri-market-orion-frontend) and [Zuri Market - Backend](https://github.com/Tonyb23/zuri-market-orion-backend) for more details


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

## 11 Future Improvement Opportunities

### Infrastructure 

| Improvement | Why it matters |
|---|---|
| Use Modules for Terraform | One large `main.tf` becomes hard to maintain; modules make infrastructure provisioning reusable |
| Replace single EC2 instance with Auto Scaling Groups | A single EC2 instance is a single point of failure — if it goes down, both the frontend and backend go with it. Auto Scaling Groups automatically replace unhealthy instances and scale out under load. |
| Replace k3s with managed EKS or ECS/Fargate | Managing a self-hosted Kubernetes cluster on a single instance means you are responsible for upgrades, high availability, and the control plane. EKS or ECS/Fargate offloads this to AWS, reducing operational risk significantly. |

### Overall Project 

| Improvement | Why it matters |
|---|---|
| Multi-environment pipeline with dev, staging, and production | All changes currently go directly to production on every push to main. A dev → staging → prod promotion model with environment-scoped GitHub Secrets means changes are validated in a lower environment before reaching real users. |
| Add HTTPS and TLS across all services end to end | All traffic currently travels over plain HTTP between the user and the frontend, and between the frontend and the backend API. HTTPS is non-negotiable for production: it protects data in transit, is required for modern browser APIs, and is expected by users. |
| Deploy a logging, monitoring, and alerting solution (ELK stack, CloudWatch or Prometheus + Grafana) | There is currently no visibility into pod health, API response times, error rates, or resource usage after deployment. Without monitoring you are blind to problems until users report them. CloudWatch or a Prometheus/Grafana stack surfaces issues proactively. |

This list is not exhaustive but provides some idea on how to move the project toward production readiness and engineering best practices

---

*Author [Anthony Ubani](https://www.linkedin.com/in/anthonyifeanyiubani/)*