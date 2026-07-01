output "alb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller"
  value       = module.alb_controller.irsa_role_arn
}

output "alb_controller_status" {
  description = "Helm release status"
  value       = module.alb_controller.helm_release_status
}

output "app_domain_name" {
  description = "Public DNS name expected by the app Ingress"
  value       = var.app_domain_name
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN expected by the app Ingress"
  value       = data.aws_acm_certificate.app.arn
}

output "next_steps" {
  description = "Steps to create the ALB after the controller is deployed"
  value       = <<-EOT
     AWS Load Balancer Controller is deployed. It will not create an ALB until a Kubernetes Ingress exists.

     1. Apply the AWS Kubernetes manifests:
         kubectl apply -k k8s-infra-aws-ssm-prod/

     2. Watch the app Ingress:
         kubectl get ingress demo-react-eks -n dev -w

     3. Get the ALB DNS name (via kubectl):
         kubectl get ingress demo-react-eks -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

     4. Get the ALB DNS name (via AWS CLI):
         aws elbv2 describe-load-balancers --region us-east-1 --names elb-react-eks-prod --query 'LoadBalancers[0].DNSName' --output text

     5. Create a CNAME record:
         ${var.app_domain_name} -> <ALB DNS hostname>

     6. Access the app:
         https://${var.app_domain_name}
  EOT
}

output "alb_frontend_sg_id" {
  description = "Frontend ALB security group ID"
  value       = aws_security_group.alb_frontend.id
}

output "alb_backend_sg_id" {
  description = "Backend ALB security group ID"
  value       = aws_security_group.alb_backend.id
}
