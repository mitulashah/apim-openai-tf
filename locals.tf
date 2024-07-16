locals {
  resource_suffix           = [lower(var.environment), lower(var.region), lower(var.application), var.resource_group_name_suffix]
  resource_suffix_kebabcase = join("-", local.resource_suffix)

  apim_sku = join("_", [var.apim_sku, var.apim_units])

  tags = merge(
    var.tags,
    tomap(
      {
        "Owner"       = var.owner_name,
        "Environment" = var.environment,
        "Region"      = var.region,
        "Application" = var.application
      }
    )
  )

  circuitBreaker = {
    rules = [
    {
      name              = "circuitBreakerRule"
      tripDuration      = "PT1H"
      acceptRetryAfter  = true # for retry-after header
      failureCondition  = {
        count             = 3
        errorReasons      = ["Server errors"]
        interval          = "PT1H"
        statusCodeRanges  = [
          {
            min = 429
            max = 429
          }, 
          {
            min = 500
            max = 599
          }]
      }
    }]
  }
}