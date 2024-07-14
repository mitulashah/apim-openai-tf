resource "azurerm_resource_group" "this" {
  name     = format("rg-%s", local.resource_suffix_kebabcase) // TOOD: reformat
  location = var.location
  tags     = local.tags
}

resource "azurerm_api_management" "this" {
  name                 = format("apim-%s", local.resource_suffix_kebabcase) // TODO: reformat
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
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
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
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
  name                  = format("oai-%s", local.resource_suffix_kebabcase)  // TODO: reformat
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  tags                  = local.tags
  custom_subdomain_name = format("oai-%s", local.resource_suffix_kebabcase) // TODO: pull from vars

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
  principal_id         = azurerm_api_management.this.identity[0].principal_id
}

resource "azurerm_api_management_backend" "open_ai" {
  name                = "azure-open-ai-backend"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http" // TODO: https?
  url                 = format("%sopenai", azurerm_cognitive_account.open_ai.endpoint) // TOOD: reformat
}

resource "azurerm_api_management_api_policy" "global_open_ai_policy" {
  api_name            = azurerm_api_management_api.open_ai.name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name

  xml_content = data.template_file.global_open_ai_policy.rendered
}