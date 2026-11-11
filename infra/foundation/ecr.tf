resource "aws_ecr_repository" "app" {
  name = var.app_name

  # Tags stay mutable on purpose: Cosign stores signatures as tags (sha256-<digest>.sig), and a re-run of the
  # signing step would fail on an immutable repository. Integrity comes from deploying by digest instead:
  # the GitOps values pin image@sha256:..., which can never point at different content.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged layers after 14 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 50 most recent images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 50 }
        action       = { type = "expire" }
      }
    ]
  })
}
