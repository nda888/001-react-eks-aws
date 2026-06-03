output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — use this to create IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL (without https://)"
  value       = module.eks.oidc_provider_url
}

output "node_group_role_arn" {
  description = "IAM role ARN for worker nodes"
  value       = module.eks.node_group_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for the Kubernetes Cluster Autoscaler service account"
  value       = module.eks.cluster_autoscaler_role_arn
}

output "cluster_security_group_id" {
  description = "AWS-generated EKS cluster security group ID"
  value       = module.eks.cluster_security_group_id
}

output "cluster_autoscaler_service_account_name" {
  description = "Kubernetes ServiceAccount name used by Cluster Autoscaler"
  value       = module.eks.cluster_autoscaler_service_account_name
}

output "cluster_security_group_name" {
  description = "Display Name tag intended for the AWS-generated EKS cluster security group"
  value       = module.eks.cluster_security_group_name
}

output "kubeconfig_command" {
  description = "Run this command to update your kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
