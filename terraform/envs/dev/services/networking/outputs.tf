output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.networking.public_subnet_ids
}

output "edge_public_subnet_ids" {
  description = "Edge public subnet IDs for shared DEV/UAT ALB + ECS"
  value       = module.networking.edge_public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.networking.private_subnet_ids
}

output "vpc_cidr_block" {
  description = "VPC CIDR block"
  value       = module.networking.vpc_cidr_block
}
