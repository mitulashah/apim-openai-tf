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

variable "owner_name" {
  description = "The name of the project's owner"
  type        = string
  default     = "owner"
}

variable "owner_email" {
  description = "The email of the project's owner"
  type        = string
  default     = "email@domain.com"
}

variable "apim_sku" {
  description = "The SKU of the API Management instance"
  type        = string
  default     = "Developer"
  validation {
    condition     = can(regex("(Consumption|Developer|Basic|Standard|Premium)", var.apim_sku))
    error_message = "The APIM SKU value must be a valid."
  }
}

variable "apim_units" {
  description = "The number of units for the API Management instance"
  type        = number
  default     = 1
}

variable "open_ai_model" {
  description = "The name of the OpenAI model"
  type        = string
  default     = "gpt-35-turbo"
}

variable "open_ai_model_version" {
  description = "The version of the OpenAI model"
  type        = string
  default     = "0301"
}

variable "open_ai_capacity" {
  description = "The number of instances of the OpenAI model in thousands"
  type        = number
  default     = 5
}

variable "resource_group_name_suffix" {
  type        = string
  default     = "01"
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