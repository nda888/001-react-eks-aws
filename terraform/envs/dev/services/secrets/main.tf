terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Data sources — EKS remote state and cluster auth
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dev/services/eks/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "eks_alb" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dev/services/eks-alb/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_eks_cluster" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

data "aws_eks_cluster_auth" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = {
    Project     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "secrets"
  }

  ssm_parameter_arn_prefix = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/*"

  oidc_provider_url = data.terraform_remote_state.eks.outputs.oidc_provider_url
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn

  mongo_ssm_parameters = {
    root_username   = "${var.ssm_prefix}/root_username"
    root_password   = "${var.ssm_prefix}/root_password"
    app_username    = "${var.ssm_prefix}/app_username"
    app_password    = "${var.ssm_prefix}/app_password"
    app_mongodb_uri = "${var.ssm_prefix}/app_mongodb_uri"
  }
}

# ---------------------------------------------------------------------------
# Namespace: external-secrets
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = var.external_secrets_namespace
    labels = {
      "app.kubernetes.io/name" = "external-secrets"
    }
  }
}

# ---------------------------------------------------------------------------
# Namespace guard: dev namespace must exist (owned by eks-alb)
# ---------------------------------------------------------------------------

data "kubernetes_namespace" "dev" {
  metadata {
    name = var.namespace
  }

  depends_on = [data.terraform_remote_state.eks_alb]
}

# ---------------------------------------------------------------------------
# IRSA: External Secrets Operator — read-only SSM access
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eso_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.external_secrets_namespace}:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.cluster_name}-external-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "eso_ssm_read" {
  statement {
    sid    = "AllowSSMReadMongoSecrets"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [local.ssm_parameter_arn_prefix]
  }
}

resource "aws_iam_policy" "eso_ssm_read" {
  name        = "${var.cluster_name}-eso-ssm-read"
  description = "Allow ESO to read Mongo SSM parameters under ${var.ssm_prefix}"
  policy      = data.aws_iam_policy_document.eso_ssm_read.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eso_ssm_read" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.eso_ssm_read.arn
}

# ---------------------------------------------------------------------------
# Helm: External Secrets Operator
# ---------------------------------------------------------------------------

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = var.external_secrets_namespace
  version          = var.external_secrets_chart_version
  create_namespace = false

  set = [
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "external-secrets"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.external_secrets.arn
    },
  ]

  depends_on = [
    kubernetes_namespace.external_secrets,
    aws_iam_role_policy_attachment.eso_ssm_read,
  ]
}

# ---------------------------------------------------------------------------
# IRSA: Mongo rotation CronJob — SSM get/put for app and root password parameters
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "mongo_rotation_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:mongo-credential-rotator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mongo_rotation" {
  name               = "${var.cluster_name}-mongo-rotation-role"
  assume_role_policy = data.aws_iam_policy_document.mongo_rotation_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "mongo_rotation_ssm" {
  statement {
    sid    = "AllowSSMReadWriteMongoRotationParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:PutParameter",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/root_password",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/app_username",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/app_password",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/app_mongodb_uri",
    ]
  }
}

resource "aws_iam_policy" "mongo_rotation_ssm" {
  name        = "${var.cluster_name}-mongo-rotation-ssm"
  description = "Allow rotation CronJob to read/write Mongo SSM parameters (app + root)"
  policy      = data.aws_iam_policy_document.mongo_rotation_ssm.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "mongo_rotation_ssm" {
  role       = aws_iam_role.mongo_rotation.name
  policy_arn = aws_iam_policy.mongo_rotation_ssm.arn
}

resource "kubernetes_service_account" "mongo_credential_rotator" {
  metadata {
    name      = "mongo-credential-rotator"
    namespace = var.namespace

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.mongo_rotation.arn
    }

    labels = {
      "app.kubernetes.io/name"       = "mongo-credential-rotator"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.mongo_rotation_ssm,
    data.kubernetes_namespace.dev,
  ]
}

# ---------------------------------------------------------------------------
# Initial Mongo SSM SecureString parameters
# ---------------------------------------------------------------------------

resource "random_password" "mongo_root" {
  length  = 32
  special = false
}

resource "random_password" "mongo_app" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "mongo_root_username" {
  name  = local.mongo_ssm_parameters.root_username
  type  = "SecureString"
  value = var.mongo_root_username
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "mongo_root_password" {
  name  = local.mongo_ssm_parameters.root_password
  type  = "SecureString"
  value = random_password.mongo_root.result
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "mongo_app_username" {
  name  = local.mongo_ssm_parameters.app_username
  type  = "SecureString"
  value = var.mongo_app_username
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "mongo_app_password" {
  name  = local.mongo_ssm_parameters.app_password
  type  = "SecureString"
  value = random_password.mongo_app.result
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "mongo_app_mongodb_uri" {
  name  = local.mongo_ssm_parameters.app_mongodb_uri
  type  = "SecureString"
  value = "mongodb://${var.mongo_app_username}:${random_password.mongo_app.result}@${var.mongo_host}/${var.mongo_database_name}?authSource=admin"
  tags  = local.common_tags
}
