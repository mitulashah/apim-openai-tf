resource "azurerm_resource_group" "rg" {
  name     = format("rg-%s", local.resource_suffix_kebabcase) 
  location = var.location
  tags     = local.tags
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

// TODO: add variable to define how many OpenAI endpoints to create
resource "azurerm_api_management_api" "open_ai" {
  name                = "api-azure-open-ai"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "Azure Open API"
  path                = "openai"
  protocols           = ["https"]

  import {
    content_format = "openapi+json"
    content_value  =  data.template_file.open_ai_spec.rendered
  }
}

resource "azurerm_cognitive_account" "open_ai" {
  name                  = format("oai-%s", local.resource_suffix_kebabcase) 
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  tags                  = local.tags
  custom_subdomain_name = format("oai-%s", local.resource_suffix_kebabcase)

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "chat_model" {
  name                 = var.open_ai_model
  cognitive_account_id = azurerm_cognitive_account.open_ai.id
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

resource "azurerm_role_assignment" "this" {
  scope                = azurerm_cognitive_account.open_ai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_api_management_backend" "open_ai" {
  name                = "azure-open-ai-backend"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  protocol            = "http" // TODO: https?
  url                 = format("%sopenai", azurerm_cognitive_account.open_ai.endpoint)
}

resource "azurerm_api_management_api_policy" "global_open_ai_policy" {
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