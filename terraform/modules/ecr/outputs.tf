output "repository_url" {
  description = "Full ECR repository URL"
  value       = aws_ecr_repository.main.repository_url
}

output "repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.main.arn
}

output "registry_id" {
  description = "AWS account ID associated with the registry"
  value       = aws_ecr_repository.main.registry_id
}
