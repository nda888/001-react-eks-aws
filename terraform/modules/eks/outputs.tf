output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}


output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL (without https://)"
  value       = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

output "node_group_role_arn" {
  description = "IAM role ARN for the managed node group"
  value       = aws_iam_role.node_group.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for the Kubernetes Cluster Autoscaler service account"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "cluster_autoscaler_service_account_name" {
  description = "Kubernetes ServiceAccount name used by Cluster Autoscaler"
  value       = "cluster-autoscaler"
}

output "cluster_security_group_id" {
  description = "AWS-generated EKS cluster security group ID"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "cluster_security_group_name" {
  description = "Display Name tag intended for the AWS-generated EKS cluster security group"
  value       = var.cluster_name
}

output "stateful_node_group_name" {
  description = "Stateful workload node group name (empty string if not enabled)"
  value       = var.stateful_node_group_enabled ? aws_eks_node_group.stateful[0].node_group_name : ""
}
