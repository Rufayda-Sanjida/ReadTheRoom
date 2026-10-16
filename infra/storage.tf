# ECR: where GitHub Actions pushes the Docker images. S3: uploaded videos. RDS: the database.

resource "aws_ecr_repository" "app" {
  for_each             = toset(["backend", "frontend"])
  name                 = "${var.project}-${each.key}"
  image_tag_mutability = "MUTABLE" # :latest is moved on every deploy
  force_delete         = true      # let `terraform destroy` remove repos that still hold images

  image_scanning_configuration {
    scan_on_push = true # free basic vulnerability scan of each image
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 newest images; storage is billed per GB"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# --- Videos ----------------------------------------------------------------------------------

resource "aws_s3_bucket" "videos" {
  bucket        = "${var.project}-videos-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # `terraform destroy` deletes uploaded videos too
}

resource "aws_s3_bucket_public_access_block" "videos" {
  bucket                  = aws_s3_bucket.videos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Browsers fetch videos straight from S3 (the backend redirects to a temporary signed link),
# so S3 must allow reads from the app's page.
resource "aws_s3_bucket_cors_configuration" "videos" {
  bucket = aws_s3_bucket.videos.id
  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}

# --- Database --------------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = var.project
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "main" {
  identifier     = var.project
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "readtheroom"
  username = "readtheroom"
  # RDS generates the password and keeps it in Secrets Manager; it never appears in code or state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false # a standby copy would double the cost

  backup_retention_period = 1
  apply_immediately       = true
  # Portfolio settings: `terraform destroy` removes the database without a final backup.
  skip_final_snapshot = true
  deletion_protection = false
}
