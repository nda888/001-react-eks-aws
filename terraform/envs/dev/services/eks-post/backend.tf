terraform {
  backend "s3" {
    bucket       = "demo-react-express-s3"
    key          = "dev/services/eks-post/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
