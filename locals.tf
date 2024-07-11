locals {
  resource_suffix           = [lower(var.environment), lower(var.region), substr(lower(var.application), 0, 3), substr(lower(var.owner), 0, 3), var.resource_group_name_suffix]
  resource_suffix_kebabcase = join("-", local.resource_suffix)

  chat_model_name               = "gpt-35-turbo"

  tags = merge(
    var.tags,
    tomap(
      {
        "Owner"       = var.owner,
        "Environment" = var.environment,
        "Region"      = var.region,
        "Application" = var.application
      }
    )
  )
}