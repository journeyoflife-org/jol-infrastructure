# =============================================================================
# Module: IAM — Roles, IRSA Service Accounts
# Least-privilege IAM per service; IRSA for pod-level AWS access
# SOC 2 CC6.1 — Logical access controls
# =============================================================================

# ---------------------------------------------------------------------------
# IRSA — External Secrets Operator
# ---------------------------------------------------------------------------
module "irsa_external_secrets" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.40"

  role_name                     = "${var.project}-${var.environment}-external-secrets"
  attach_external_secrets_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# IRSA — Cert Manager
# ---------------------------------------------------------------------------
module "irsa_cert_manager" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.40"

  role_name                      = "${var.project}-${var.environment}-cert-manager"
  attach_cert_manager_policy     = false

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# IRSA — EBS CSI Driver
# ---------------------------------------------------------------------------
module "irsa_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.40"

  role_name             = "${var.project}-${var.environment}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Custom Policy — Read-only monitoring
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "monitoring_reader" {
  name        = "${var.project}-${var.environment}-monitoring-reader"
  description = "Read-only access to CloudWatch and X-Ray for monitoring stack"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:Describe*",
          "cloudwatch:Get*",
          "cloudwatch:List*",
          "logs:Get*",
          "logs:List*",
          "logs:Describe*",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:FilterLogEvents",
          "xray:Get*",
          "xray:BatchGet*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}
