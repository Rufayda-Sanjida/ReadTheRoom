# Deploying ReadTheRoom on AWS

Everything in this folder is **Terraform**: code that describes the AWS setup. `terraform apply`
creates it, `terraform destroy` deletes all of it.

```
                         ┌──────────────────────────── AWS (us-east-1) ─────────────────────────────┐
                         │  VPC                                                                       │
 browser ──HTTP──────────┼─► Load balancer ──► frontend (ECS Fargate, :3000)                          │
                         │                         │  /api/* proxied to                               │
                         │                         ▼                                                  │
                         │                     backend (ECS Fargate, :8000) ──► RDS Postgres          │
                         │                         │                            (private subnet)      │
                         │                         └──► S3 (uploaded videos)                          │
                         │                                                                            │
                         │  Secrets Manager (API keys, DB password)   CloudWatch (logs, alarms, dash) │
                         └────────────────────────────────────────────────────────────────────────────┘
 GitHub Actions ──OIDC──► push images to ECR ──► redeploy ECS services
```

| File | What it creates |
|---|---|
| `network.tf` | VPC, subnets, and security groups (who may talk to whom) |
| `storage.tf` | ECR image repos, S3 bucket for videos, RDS Postgres |
| `ecs.tf` | ECS cluster, the frontend and backend services, the load balancer |
| `iam.tf` | Permissions, and the Secrets Manager secret for API keys |
| `monitoring.tf` | CloudWatch alarms (emailed to you) and a dashboard |
| `github.tf` | Lets GitHub Actions deploy with no stored AWS keys (OIDC) |
| `bootstrap/` | One-time: the S3 bucket that stores Terraform's own state |

**Cost:** about $25–40/month while it's up. The load balancer (~$17) is the biggest piece;
Fargate Spot keeps the containers at ~$5 each; RDS `db.t4g.micro` is free-tier eligible.
There's no NAT Gateway (that would add ~$32). Run `terraform destroy` when you don't need it live.

---

## First-time setup

### 0. Tools and AWS login

```bash
brew install awscli hashicorp/tap/terraform
aws configure          # paste the access key of your IAM user; region: us-east-1
aws sts get-caller-identity   # should print your account id
```

Set a billing alert first: AWS console → Billing → Budgets → Create budget → "Monthly cost budget", $10.

### 1. State bucket (once)

```bash
cd infra/bootstrap
terraform init
terraform apply        # type "yes"
```

It prints the contents for `infra/backend.hcl`. Create that file, then:

```bash
cd ..                  # back to infra/
terraform init -backend-config=backend.hcl
```

### 2. Create everything

```bash
cp terraform.tfvars.example terraform.tfvars   # put your email in it for alarms
terraform apply                                 # ~10 minutes, mostly the database
```

AWS emails you a link to confirm the alarm subscription. Click it.

The site won't load yet: there are no Docker images until GitHub Actions builds them (step 4).

### 3. API keys

The keys go straight into AWS Secrets Manager, never into the repo. Leave out any you don't have;
without an LLM key the chat falls back to keyword answers.

```bash
aws secretsmanager put-secret-value --secret-id readtheroom/app-keys --secret-string '{
  "GEMINI_API_KEY": "...",
  "ANTHROPIC_API_KEY": "",
  "SMARTSPECTRA_API_KEY": "..."
}'
```

Containers read the keys when they start, so after changing them, redeploy (step 4 or the
"Run workflow" button).

### 4. Connect GitHub Actions

```bash
terraform output github_deploy_role_arn
```

On GitHub: repo → **Settings → Secrets and variables → Actions → Variables tab → New repository
variable**, name `AWS_ROLE_ARN`, value = that ARN. (It's not a secret: the role only trusts
workflows on this repo's `main` branch.)

Then **Actions → Test and deploy → Run workflow**. When it's green:

```bash
terraform output app_url
```

From now on, every push to `main` tests, builds and deploys automatically.

---

## Day to day

| I want to… | Do this |
|---|---|
| Deploy code | Push to `main` |
| See logs | CloudWatch → Log groups → `/ecs/readtheroom/backend` (or `frontend`) |
| See the dashboard | `terraform output dashboard_url` |
| Change infrastructure | Edit the `.tf` files, `terraform plan` to preview, `terraform apply` |
| Stop paying | `terraform destroy` (deletes the database and videos too). `terraform apply` + "Run workflow" brings it back |

## Not set up (yet)

- **HTTPS / custom domain**: needs a domain name; then an ACM certificate and a port-443 listener.
- **Autoscaling**: each service runs one container; `desired_count` or an autoscaling policy would add more.
