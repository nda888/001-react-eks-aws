output "backend_repository_url" {
  description = "ECR repository URL for backend image"
  value       = module.backend_ecr.repository_url
}

output "frontend_repository_url" {
  description = "ECR repository URL for frontend image"
  value       = module.frontend_ecr.repository_url
}

output "backend_repository_arn" {
  description = "ECR repository ARN for backend"
  value       = module.backend_ecr.repository_arn
}

output "frontend_repository_arn" {
  description = "ECR repository ARN for frontend"
  value       = module.frontend_ecr.repository_arn
}

output "registry_id" {
  description = "AWS account ID of the registry"
  value       = module.backend_ecr.registry_id
}
