# Fetch Terraform runner public IP only when auto-allowlist mode is enabled.
data "http" "current_public_ip" {
  count = var.include_current_public_ip ? 1 : 0
  url   = "https://ipinfo.io/ip"
}

locals {
  current_public_ip_cidrs = var.include_current_public_ip ? [
    "${chomp(data.http.current_public_ip[0].response_body)}/32"
  ] : []

  effective_public_access_cidrs = distinct(concat(
    var.public_access_cidrs,
    local.current_public_ip_cidrs
  ))
}
