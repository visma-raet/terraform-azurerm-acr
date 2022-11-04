#---------------------------------------------------------
# Local Declarations
#---------------------------------------------------------
locals {
  resource_group_name = element(coalescelist(data.azurerm_resource_group.rgrp.*.name, azurerm_resource_group.rg.*.name, [""]), 0)
  location            = element(coalescelist(data.azurerm_resource_group.rgrp.*.location, azurerm_resource_group.rg.*.location, [""]), 0)
  roles_map           = { for role in var.roles : "${role.ppal_id}.${role.role}" => role }
}

#---------------------------------------------------------
# Data
#---------------------------------------------------------
data "azurerm_client_config" "current" {}


#---------------------------------------------------------
# Resources
#---------------------------------------------------------

data "azurerm_resource_group" "rgrp" {
  count = var.create_resource_group == false ? 1 : 0
  name  = var.resource_group_name
}

resource "azurerm_resource_group" "rg" {
  #ts:skip=AC_AZURE_0389 RSG lock should be skipped for now.
  count    = var.create_resource_group ? 1 : 0
  name     = lower(var.resource_group_name)
  location = var.location
  tags     = merge({ "ResourceName" = format("%s", var.resource_group_name) }, var.tags, )
}

resource "azurerm_container_registry" "acr" {
  #ts:skip=AC_AZURE_0185 ACR lock should be skipped for now.
  name                      = var.name
  resource_group_name       = local.resource_group_name
  location                  = local.location
  sku                       = var.sku
  admin_enabled             = var.admin_enabled
  quarantine_policy_enabled = var.sku == "Premium" ? var.quarantine_policy_enabled : false
  #System  Managed Identity generated or User Managed Identity ID's which should be assigned to the Container Registry.
  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.identity_id.id
    ]
  }
  trust_policy {
    enabled = var.content_trust
  }

  dynamic "georeplications" {
    for_each = var.sku == "Premium" ? ["georeplica_activated"] : []
    content {
      location = var.georeplication_location
    }
  }

  dynamic "retention_policy" {
    for_each = var.sku == "Premium" ? ["retention_policy_activated"] : []
    content {
      days    = var.retention_policy["days"]
      enabled = var.retention_policy["enabled"]
    }
  }

  dynamic "encryption" {
    for_each = var.encryption.enabled == true && var.encryption.key_vault_key_id != null && var.encryption.identity_client_id != null ? ["encryption_activated"] : []
    content {
      enabled            = var.content_trust == true ? false : var.encryption.enabled
      key_vault_key_id   = var.encryption.key_vault_key_id
      identity_client_id = var.encryption.identity_client_id
    }
  }
}

resource "azurerm_user_assigned_identity" "identity_id" {
  resource_group_name = azurerm_resource_group.rg[0].name
  location            = azurerm_resource_group.rg[0].location

  name = "registry-uai"
}

resource "azurerm_role_assignment" "roles" {
  for_each = local.roles_map

  scope                = azurerm_container_registry.acr.id
  role_definition_name = each.value.role
  principal_id         = each.value.ppal_id

}

provider "azurerm" {
  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_delete_on_destroy               = true
      purge_soft_deleted_secrets_on_destroy      = true
      purge_soft_deleted_certificates_on_destroy = true
    }
  }
  skip_provider_registration = true
}
