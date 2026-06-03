output "effective_public_access_cidrs" {
  description = "Final public access CIDR allowlist."
  value       = local.effective_public_access_cidrs

  precondition {
    condition     = length(local.effective_public_access_cidrs) > 0
    error_message = "No public access CIDRs resolved. Set public_access_cidrs or enable include_current_public_ip."
  }
}
