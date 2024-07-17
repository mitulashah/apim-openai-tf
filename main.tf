resource "azurerm_resource_group" "rg" {
  name     = format("rg-%s", local.resource_suffix_kebabcase) 
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "log" {
  name                = format("log-%s", local.resource_suffix_kebabcase) 
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "appi" {
  name                = format("appi-%s", local.resource_suffix_kebabcase) 
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.log.id
  application_type    = "web"
  tags                = local.tags
}

resource "azurerm_api_management_logger" "apim-logger" {
  name                 = format("apim-logger-%s", local.resource_suffix_kebabcase) 
  resource_group_name  = azurerm_resource_group.rg.name
  api_management_name  = azurerm_api_management.apim.name
  
  application_insights {
    instrumentation_key = azurerm_application_insights.appi.instrumentation_key
  }
}

resource "azurerm_api_management_diagnostic" "apim-logger-settings" {
  identifier               = "applicationinsights"
  resource_group_name      = azurerm_resource_group.rg.name
  api_management_name      = azurerm_api_management.apim.name
  api_management_logger_id = azurerm_api_management_logger.apim-logger.id

  sampling_percentage       = 5.0
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "verbose"
  http_correlation_protocol = "W3C"
}

resource "azurerm_api_management" "apim" {
  name                 = format("apim-%s", local.resource_suffix_kebabcase) 
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  publisher_name       = var.owner_name
  publisher_email      = var.owner_email
  sku_name             = local.apim_sku
  tags                 = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# Only need a single API in APIM
resource "azurerm_api_management_api" "open_ai" {
  name                  = "api-azure-open-ai" 
  resource_group_name   = azurerm_resource_group.rg.name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Azure OpenAI API" 
  path                  = "openai" 
  protocols             = ["https"]
  subscription_required = true

  # required to stay compatible with OpenAI SDKs
  subscription_key_parameter_names {
    header = "api-key"
    query = "api-key"
  }

  import {
    content_format = "openapi+json"
    content_value  =  data.template_file.open_ai_spec.rendered
  }
}

# ================================================================================================== 
# Loop through OpenAI Endpoints
# ================================================================================================== 

resource "azurerm_cognitive_account" "open_ai" {

  for_each = var.open_ai_instances

  name                  = format("aoai-%s-%s", each.key, local.resource_suffix_kebabcase) 
  location              = each.value.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  tags                  = local.tags
  custom_subdomain_name = format("aoai-api-%s", each.key)

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "chat_model" {

  for_each = azurerm_cognitive_account.open_ai

  name                 = var.open_ai_model
  cognitive_account_id = each.value.id
  model {
    format  = "OpenAI"
    name    = var.open_ai_model
    version = var.open_ai_model_version
  }

  scale {
    type     = "Standard"
    capacity = var.open_ai_capacity
  }
}

resource "azurerm_role_assignment" "role" {

  for_each = azurerm_cognitive_account.open_ai

  scope                = each.value.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azapi_resource" "backend" {

  for_each = azurerm_cognitive_account.open_ai

  type = "Microsoft.ApiManagement/service/backends@2023-05-01-preview"
  name = format("aoai-backend-%s", each.key)
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      url = format("%sopenai", azurerm_cognitive_account.open_ai[each.key].endpoint)
      protocol = "http"
      circuitBreaker = local.circuitBreaker
    }
  }

  schema_validation_enabled = false
}

resource "azapi_resource" "pool" {
  type = "Microsoft.ApiManagement/service/backends@2023-05-01-preview"
  name = "aoai-backend-pool"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      description = "Load balancer for multiple Azure OpenAI backends (equal priority and weight)"
      type = "Pool"
      pool = {
        services = [
          for backend in azapi_resource.backend : {
            id = backend.id
            priority = 1
            weight = 1
          }
        ]
      }
    }
  }

  schema_validation_enabled = false
}

resource "azurerm_api_management_api_policy" "global_open_ai_policy" {
  depends_on = [ azapi_resource.pool ]

  api_name            = azurerm_api_management_api.open_ai.name
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name

  xml_content         = data.template_file.global_open_ai_policy.rendered
}

# ================================================================================================== 
# Azure Front Door Configuration
# ================================================================================================== 

resource "azurerm_cdn_frontdoor_profile" "afd" {
  name                = format("afd-%s", local.resource_suffix_kebabcase) 
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
  sku_name            = "Premium_AzureFrontDoor"
}

resource "azurerm_cdn_frontdoor_endpoint" "afd-endpoint" {
  name                      = var.afd_host_name_prefix
  cdn_frontdoor_profile_id  = azurerm_cdn_frontdoor_profile.afd.id
  tags                      = local.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "afd-origin-grp" {
  name                      = format("origingrp-%s", local.resource_suffix_kebabcase)
  cdn_frontdoor_profile_id  = azurerm_cdn_frontdoor_profile.afd.id

  health_probe {
    interval_in_seconds = 30
    path                = "/status-0123456789abcdef"
    protocol            = "Https"
    request_type        = "GET"
  }

  load_balancing {
    sample_size                         = 4
    successful_samples_required         = 3
    additional_latency_in_milliseconds  = 50
  }
}

resource "azurerm_cdn_frontdoor_origin" "afd-origin" {
  name                            = format("origin-%s", local.resource_suffix_kebabcase)
  cdn_frontdoor_origin_group_id   = azurerm_cdn_frontdoor_origin_group.afd-origin-grp.id
  enabled                         = true
  certificate_name_check_enabled  = true

  host_name           = replace(lower(trim(azurerm_api_management.apim.gateway_url, " /")), "https://", "")
  origin_host_header  = replace(lower(trim(azurerm_api_management.apim.gateway_url, " /")), "https://", "")
  http_port           = 80
  https_port          = 443
  priority            = 1
  weight              = 1
}

resource "azurerm_cdn_frontdoor_route" "afd-route" {
  name                          = format("route-%s", local.resource_suffix_kebabcase)
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.afd-endpoint.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.afd-origin-grp.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.afd-origin.id]
  enabled                       = true

  supported_protocols = ["Http", "Https"]
  forwarding_protocol = "MatchRequest"
  patterns_to_match   = ["/*"]

  cache {
    query_string_caching_behavior = "UseQueryString"
  }
}

resource "azurerm_cdn_frontdoor_firewall_policy" "waf-policy" {
  name                        = var.waf_policy_name
  resource_group_name         = azurerm_resource_group.rg.name
  tags                        = local.tags
  sku_name                    = "Premium_AzureFrontDoor"
  enabled                     = true
  mode                        = var.waf_mode
  request_body_check_enabled  = true

  managed_rule {
    type      = "DefaultRuleSet"
    version   = "1.0"
    action    = "Block"
  }

  managed_rule {
    type      = "Microsoft_BotManagerRuleSet"
    version   = "1.1"
    action    = "Block"
  }
}

resource "azurerm_cdn_frontdoor_security_policy" "waf-secure" {
  name                        = format("waf-secure-%s", local.resource_suffix_kebabcase)
  cdn_frontdoor_profile_id    = azurerm_cdn_frontdoor_profile.afd.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id  = azurerm_cdn_frontdoor_firewall_policy.waf-policy.id

      association {
        domain {
          cdn_frontdoor_domain_id       = azurerm_cdn_frontdoor_endpoint.afd-endpoint.id
        }
        patterns_to_match               = ["/*"]
      }
    }
  }
}

# Create named value in APIM for Front Door ID for access restriction
resource "azurerm_api_management_named_value" "afd-id" {
  name                 = "frontdoor-header-id"
  resource_group_name  = azurerm_resource_group.rg.name
  api_management_name  = azurerm_api_management.apim.name
  display_name         = "frontdoor-header-id"
  value                = azurerm_cdn_frontdoor_profile.afd.resource_guid
}