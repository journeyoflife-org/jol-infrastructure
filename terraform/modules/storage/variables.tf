# =============================================================================
# Module: Storage — Variables
# =============================================================================

variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "create_app_bucket" {
  description = "Create application data S3 bucket"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "enable_ebs_encryption" {
  description = "Enable default EBS encryption for the AWS account/region"
  type        = bool
  default     = true
}
