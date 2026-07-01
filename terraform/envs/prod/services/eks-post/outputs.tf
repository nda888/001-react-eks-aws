output "cluster_autoscaler_service_account_name" {
  description = "Kubernetes ServiceAccount name used by Cluster Autoscaler"
  value       = kubernetes_service_account_v1.cluster_autoscaler.metadata[0].name
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN used by Cluster Autoscaler ServiceAccount"
  value       = data.terraform_remote_state.eks.outputs.cluster_autoscaler_role_arn
}
