# =============================================================================
# Bootstrap — Variables
# =============================================================================

variable "aws_region" {
  description = "AWS region for state resources"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "jol"
}

variable "environments" {
  description = "List of environments to bootstrap"
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
