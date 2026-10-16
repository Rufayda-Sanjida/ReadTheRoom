variable "region" {
  description = "AWS region everything is created in."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "readtheroom"
}

variable "github_repo" {
  description = "owner/name of the GitHub repo allowed to deploy (via GitHub Actions)."
  type        = string
  default     = "Rufayda-Sanjida/ReadTheRoom"
}

variable "create_github_oidc_provider" {
  description = "An AWS account can trust GitHub's login only once. Set false if your account already has it (e.g. from another project)."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Where CloudWatch alarms are emailed. AWS sends a confirmation link first. Empty = no emails."
  type        = string
  default     = ""
}

variable "use_fargate_spot" {
  description = "Run containers on spare AWS capacity (~70% cheaper). AWS can reclaim it with 2 minutes' notice; ECS then starts a replacement. Fine for a portfolio app."
  type        = bool
  default     = true
}

variable "db_instance_class" {
  description = "RDS size. db.t4g.micro is the smallest and is covered by the free tier."
  type        = string
  default     = "db.t4g.micro"
}
