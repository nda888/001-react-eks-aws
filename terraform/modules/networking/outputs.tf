output "vpc_id" {
  description = "VPC ID"
  value       = data.aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = local.all_public_subnet_ids
}

output "edge_public_subnet_ids" {
  description = "List of edge public subnet IDs (filtered by edge_public_subnet_azs when provided)"
  value       = local.edge_public_subnet_ids
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = var.create_private_networking ? aws_subnet.private[*].id : []
}

output "vpc_cidr_block" {
  description = "VPC CIDR block"
  value       = data.aws_vpc.main.cidr_block
}
