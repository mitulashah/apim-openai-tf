resource "azurerm_resource_group" "this" {
  name     = format("rg-%s", local.resource_suffix_kebabcase)
  location = var.location
  tags     = local.tags
}

resource "azurerm_api_management" "this" {
  name                 = format("apim-%s", local.resource_suffix_kebabcase)
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
  publisher_name       = "Mitul Shah"
  publisher_email      = "mitulshah@microsoft.com"
  sku_name             = "Developer_1"
  tags                 = local.tags

  identity {
    type = "SystemAssigned"
  }
}

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
  name                  = format("oai-%s", local.resource_suffix_kebabcase)
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  tags                  = local.tags
  custom_subdomain_name = format("oai-%s", local.resource_suffix_kebabcase)

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "chat_model" {
  name                 = local.chat_model_name
  cognitive_account_id = azurerm_cognitive_account.open_ai.id
  model {
    format  = "OpenAI"
    name    = local.chat_model_name
    version = "0301"
  }

  scale {
    type     = "Standard"
    capacity = 5
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
  protocol            = "http"
  url                 = format("%sopenai", azurerm_cognitive_account.open_ai.endpoint)
}

resource "azurerm_api_management_api_policy" "global_open_ai_policy" {
  api_name            = azurerm_api_management_api.open_ai.name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name

  xml_content = data.template_file.global_open_ai_policy.rendered
}


resource "azurerm_virtual_network" "vnet" {
  name = format("vnet-%s", local.resource_suffix_kebabcase)
  address_space = ["10.100.0.0/16"]
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
}

resource "azurerm_network_security_group" "vnet-agw-nsg" {
  name                = format("nsg-agw-%s", local.resource_suffix_kebabcase)
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name

  security_rule {
    access                                     = "Allow"
    destination_address_prefix                 = "*"
    destination_port_range                     = "65200-65535"
    direction                                  = "Inbound"
    name                                       = "AllowBackendHealthPortsInBound"
    priority                                   = 100
    protocol                                   = "Tcp"
    source_address_prefix                      = "*"
    source_port_range                          = "*"
  }

  security_rule {
    access                                     = "Allow"
    destination_address_prefix                 = "*"
    destination_port_range                     = "443"
    direction                                  = "Inbound"
    name                                       = "AllowApiManagerHttpsInBound"
    priority                                   = 110
    protocol                                   = "Tcp"
    source_address_prefix                      = "*"
    source_port_range                          = "*"
  }
}

resource "azurerm_subnet" "vnet-agw-subnet" {
  address_prefixes = ["10.100.0.128/27"]
  virtual_network_name = azurerm_virtual_network.vnet.name
  name = format("snet-agw-%s", local.resource_suffix_kebabcase)
  resource_group_name   = azurerm_resource_group.this.name
}

resource "azurerm_subnet_network_security_group_association" "vnet-agw-nsg-association" {
  subnet_id                 = azurerm_subnet.vnet-agw-subnet.id
  network_security_group_id = azurerm_network_security_group.vnet-agw-nsg.id
}

resource "azurerm_public_ip" "vnet-agw-pip" {
  name                = format("pip-agw-%s", local.resource_suffix_kebabcase)
  sku                 = "Standard"
  allocation_method   = "Static"
  domain_name_label   = format("app-%s", local.resource_suffix_kebabcase)
  zones = []
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
}

resource "azurerm_application_gateway" "agw" {
  name = format("agw-%s", local.resource_suffix_kebabcase)
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name

  autoscale_configuration {
    max_capacity = 10
    min_capacity = 2
  }

  frontend_port {
    name = "port_443"
    port = 443
  }

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  frontend_ip_configuration {
    name                          = "appGwPublicFrontendIp"
    public_ip_address_id          = azurerm_public_ip.vnet-agw-pip.id
    private_ip_address_allocation = "Dynamic"
  }

  backend_http_settings {
    cookie_based_affinity               = "Disabled"
    name                                = "agw-apim-poc-http-settings"
    port                                = 443
    protocol                            = "Https"
    host_name                           = "apim.contoso.com"
    pick_host_name_from_backend_address = true
    path                                = "/external/"
    request_timeout                     = 20
    probe_name                          = "agw-apim-poc-apim-probe"
    trusted_root_certificate_names      = ["agw-apim-poc-trusted-root-ca-certificate"]
  }

  probe {
    interval                                  = 30
    name                                      = "agw-apim-poc-apim-probe"
    path                                      = "/status-0123456789abcdef"
    protocol                                  = "Https"
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true
    match {
      body = ""
      status_code = [
        "200-399"
      ]
    }
  }

  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.vnet-agw-subnet.id
  }

  backend_address_pool {
    name      = "agw-apim-poc-backend-pool"
    fqdns = [trimprefix(azurerm_api_management.this.gateway_url, "https://")]
  }

  http_listener {
    frontend_ip_configuration_name = "appGwPublicFrontendIp"
    frontend_port_name             = "port_443"
    name                           = "agw-apim-poc-app-gateway-listener"
    protocol                       = "Https"
    require_sni                    = false
    ssl_certificate_name           = "agw-apim-poc-app-gateway-certificate"
  }

  ssl_certificate {
    data     = filebase64(var.ssl_certificate_path)
    name     = "agw-apim-poc-app-gateway-certificate"
    password = var.app_gateway_ssl_certificate_password
  }

  trusted_root_certificate {
    data = filebase64(var.trusted_root_certificate_path)
    name = "agw-apim-poc-trusted-root-ca-certificate"
  }

  request_routing_rule {
    http_listener_name         = "agw-apim-poc-app-gateway-listener"
    name                       = "agw-apim-poc-rule"
    rule_type                  = "Basic"
    backend_address_pool_name  = "agw-apim-poc-backend-pool"
    backend_http_settings_name = "agw-apim-poc-http-settings"
  }
}