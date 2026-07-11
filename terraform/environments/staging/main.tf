# =============================================================================
# Environment: staging
# VPC CIDR: 10.1.0.0/16
# =============================================================================

locals {
  project     = "jol"
  environment = "staging"
  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
module "networking" {
  source = "../../modules/networking"

  project               = local.project
  environment           = local.environment
  vpc_cidr              = var.vpc_cidr
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs
  availability_zones    = var.availability_zones
  cluster_name          = module.kubernetes.cluster_name
  enable_nat_gateway    = true
  multi_az_nat          = var.multi_az_nat
  tags                  = local.common_tags
}

# ---------------------------------------------------------------------------
# Kubernetes (EKS)
# ---------------------------------------------------------------------------
module "kubernetes" {
  source = "../../modules/kubernetes"

  project            = local.project
  environment        = local.environment
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  cluster_version    = var.cluster_version
  kms_key_arn        = module.storage.kms_key_arn
  node_desired_size  = var.node_desired_size
  node_max_size      = var.node_max_size
  node_min_size      = var.node_min_size
  node_instance_types = var.node_instance_types
  tags               = local.common_tags
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
module "storage" {
  source = "../../modules/storage"

  project     = local.project
  environment = local.environment
  tags        = local.common_tags
}

# ---------------------------------------------------------------------------
# IAM (IRSA)
# ---------------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  project           = local.project
  environment       = local.environment
  oidc_provider_arn = module.kubernetes.oidc_provider_arn
  oidc_provider_url = module.kubernetes.oidc_provider_url
  tags              = local.common_tags
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
module "monitoring" {
  source = "../../modules/monitoring"

  project              = local.project
  environment          = local.environment
  aws_region           = var.aws_region
  cluster_name         = module.kubernetes.cluster_name
  kms_key_arn          = module.storage.kms_key_arn
  alert_email_addresses = var.alert_email_addresses
  tags                 = local.common_tags
}
