variable "application" {
  default     = "app"
  description = "Name of the application"
  type        = string
}

variable "environment" {
  description = "The environment deployed"
  type        = string
  default     = "dev"
  validation {
    condition     = can(regex("(dev|stg|pro)", var.environment))
    error_message = "The environment value must be a valid."
  }
}

variable "region" {
  description = "Azure deployment region"
  type        = string
  default     = "east"
}

variable "location" {
  description = "Azure deployment location"
  type        = string
  default     = "eastus"
}

variable "owner" {
  description = "The name of the project's owner"
  type        = string
  default     = "mshah"
}

variable "resource_group_name_suffix" {
  type        = string
  default     = "001"
  description = "The resource group name suffix"
  validation {
    condition     = can(regex("[0-9]{2}", var.resource_group_name_suffix))
    error_message = "The resource group name suffix value must be two digits."
  }
}

variable "tags" {
  type        = map(any)
  description = "The custom tags for all resources"
  default     = {}
}