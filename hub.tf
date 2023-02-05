locals {
  hub_prefix = "brumer-final-terraform-hub"
}

#//////////////////////////////////Resource_Group/////////////////////////////////////////////
resource "azurerm_resource_group" "hub" {
  name     = "${local.hub_prefix}-rg"
  location = local.location

  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

#//////////////////////////////////Log_Analytics/////////////////////////////////////////////
locals {
  log_analytics_workspace = {
    name              = "${local.hub_prefix}-log-analytics"
    sku               = "PerGB2018"
    retention_in_days = 30
    daily_quota_gb    = -1
  }
}

resource "azurerm_log_analytics_workspace" "hub" {
  name                = local.log_analytics_workspace.name
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  sku                 = local.log_analytics_workspace.sku
  retention_in_days   = local.log_analytics_workspace.retention_in_days
  daily_quota_gb      = local.log_analytics_workspace.daily_quota_gb

  lifecycle {
    ignore_changes = [
      tags
    ]
  }

  depends_on = [
    azurerm_resource_group.hub
  ]
}

#//////////////////////////////////Route_Table/////////////////////////////////////////////
locals {
  hub_route_table_name = "${local.hub_prefix}-firewall-routetable"
  route_tables_template_variables = {
    workspoke_main_subnet_address_prefix    = module.ipam.workspoke_main_subnet_address_prefix
    monitorspoke_main_subnet_address_prefix = module.ipam.monitorspoke_main_subnet_address_prefix
    firewall_private_ip_address             = module.ipam.firewall_private_ip_address
  }
}

module "hub_route_table" {
  source = "git::https://github.com/OmerBrumer/module-route-table.git?ref=dev"

  route_table_name    = local.hub_route_table_name
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  route_tables        = jsondecode(templatefile("./routes/hub_routes.json", local.route_tables_template_variables))

  depends_on = [
    azurerm_resource_group.hub
  ]
}

#//////////////////////////////////Network_Security_Group/////////////////////////////////////////////
locals {
  hub_nsg_name = "${local.hub_prefix}-nsg"
  hub_network_security_rules_template_variables = {
    vpn_gateway_subnet_adress_prefix        = module.ipam.vpn_gateway_subnet_adress_prefix
    hub_subnet_address_prefix               = module.ipam.hub_subnet_address_prefix
    workspoke_main_subnet_address_prefix    = module.ipam.workspoke_main_subnet_address_prefix
    monitorspoke_main_subnet_address_prefix = module.ipam.monitorspoke_main_subnet_address_prefix
    firewall_private_ip_address             = module.ipam.firewall_private_ip_address
  }
}

module "hub_nsg" {
  source = "git::https://github.com/OmerBrumer/module-network-security-group.git?ref=dev"

  network_security_group_name = local.hub_nsg_name
  resource_group_name         = azurerm_resource_group.hub.name
  location                    = azurerm_resource_group.hub.location
  network_security_rules      = jsondecode(templatefile("./nsg_rules/hub_nsg_rules.json", local.hub_network_security_rules_template_variables))
  log_analytics_workspace_id  = azurerm_log_analytics_workspace.hub.id

  depends_on = [
    azurerm_log_analytics_workspace.hub
  ]
}

#//////////////////////////////////Virtual_Network/////////////////////////////////////////////
locals {
  hub_vnet_name        = "${local.hub_prefix}-vnet"
  endpoint_subnet_name = "EndpointSubnet"
  gateway_subnet_name  = "GatewaySubnet"
}

module "hub_vnet" {
  source = "git::https://github.com/OmerBrumer/module-virtual-network.git?ref=dev"

  vnet_name           = local.hub_vnet_name
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  vnet_address_space  = module.ipam.hub_vnet_address_space

  subnets = {
    "${local.endpoint_subnet_name}" = {
      subnet_address_prefixes   = [module.ipam.endpoint_subnet_address_prefix]
      route_table_id            = module.hub_route_table.id
      network_security_group_id = module.hub_nsg.id
    }

    "${local.gateway_subnet_name}" = {
      subnet_address_prefixes = [module.ipam.gateway_subnet_address_prefix]
      route_table_id          = module.hub_route_table.id
    }
  }

  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  depends_on = [
    module.hub_route_table,
    module.hub_nsg
  ]
}

#//////////////////////////////////VPN_Gateway/////////////////////////////////////////////
locals {
  vpn_gateway_name = "${local.hub_prefix}-vnet-gateway"
  vpn_client_configuration = {
    vpn_client_protocols = ["OpenVPN"]
    aad_tenant           = var.aad_tenant
  }
  enable_active_active = true
}

module "vpn_gateway" {
  source = "git::https://github.com/OmerBrumer/module-virtual-network-gateway.git?ref=dev"

  name                 = local.vpn_gateway_name
  resource_group_name  = azurerm_resource_group.hub.name
  location             = azurerm_resource_group.hub.location
  subnet_id            = module.hub_vnet.subnet_ids[local.gateway_subnet_name]
  enable_active_active = local.enable_active_active

  vpn_client_configuration = {
    address_space        = module.ipam.vpn_gateway_subnet_adress_prefix
    vpn_client_protocols = local.vpn_client_configuration.vpn_client_protocols
    aad_tenant           = local.vpn_client_configuration.aad_tenant
  }

  depends_on = [
    module.hub_vnet
  ]
}

#//////////////////////////////////Firewall/////////////////////////////////////////////
locals {
  firewall_config = {
    name              = "${local.hub_prefix}-firewall"
    sku_name          = "AZFW_VNet"
    sku_tier          = "Standard"
    threat_intel_mode = "Alert"
  }

  enable_forced_tunneling = true
  firewall_policy = {
    sku = "Standard"
  }

  network_rules_template_variables = {
    vpn_gateway_subnet_adress_prefix        = module.ipam.vpn_gateway_subnet_adress_prefix,
    endpoint_subnet_address_prefix          = module.ipam.endpoint_subnet_address_prefix,
    workspoke_main_subnet_address_prefix    = module.ipam.workspoke_main_subnet_address_prefix,
    monitorspoke_main_subnet_address_prefix = module.ipam.monitorspoke_main_subnet_address_prefix,
    monitorspoke_virtual_machine            = module.ipam.monitorspoke_virtual_machine
  }

  application_rules_template_variables = {
    workspoke_main_subnet_address_prefix    = module.ipam.workspoke_main_subnet_address_prefix,
    monitorspoke_main_subnet_address_prefix = module.ipam.monitorspoke_main_subnet_address_prefix,
    vpn_gateway_subnet_adress_prefix        = module.ipam.vpn_gateway_subnet_adress_prefix,
    workspoke_aks_subnet_address_prefix     = module.ipam.workspoke_aks_subnet_address_prefix,
    aks_fqdn                                = module.aks.private_fqdn,
    acr_name                                = module.acr.name,
    grafana_address                         = "grafana"
  }
}

module "firewall" {
  source = "git::https://github.com/OmerBrumer/module-firewall.git?ref=dev"

  virtual_network_name           = module.hub_vnet.name
  resource_group_name            = azurerm_resource_group.hub.name
  location                       = azurerm_resource_group.hub.location
  firewall_subnet_address_prefix = [module.ipam.firewall_subnet_address_prefix]
  firewall_config = {
    name              = local.firewall_config.name
    sku_name          = local.firewall_config.sku_name
    sku_tier          = local.firewall_config.sku_tier
    threat_intel_mode = local.firewall_config.threat_intel_mode
  }

  enable_forced_tunneling                   = local.enable_forced_tunneling
  firewall_management_subnet_address_prefix = [module.ipam.firewall_management_subnet_address_prefix]

  firewall_policy = {
    sku = local.firewall_policy.sku
  }

  network_rules     = jsondecode(templatefile("./firewall_policies/network_rules.json", local.network_rules_template_variables))
  application_rules = jsondecode(templatefile("./firewall_policies/application_rules.json", local.application_rules_template_variables))

  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  depends_on = [
    module.hub_vnet
  ]
}

#//////////////////////////////////Private_DNS_Zone/////////////////////////////////////////////
locals {
  private_dns_zone_name = "privatelink.azurecr.io"
}

module "acr_private_dns_zone" {
  source = "git::https://github.com/OmerBrumer/module-private-dns-zone.git?ref=dev"

  private_dns_zone_name = local.private_dns_zone_name
  resource_group_name   = azurerm_resource_group.hub.name
  location              = azurerm_resource_group.hub.location
  virtual_network_links = {
    "${module.workspoke_vnet.name}-link" = {
      virtual_network_id = module.workspoke_vnet.id
    },

    "${module.hub_vnet.name}-link" = {
      virtual_network_id = module.hub_vnet.id
    }
  }

  depends_on = [
    module.hub_vnet,
    module.workspoke_vnet
  ]
}

#//////////////////////////////////Container_Registry/////////////////////////////////////////////
locals {
  container_registry_config = {
    name                          = "brumerfinalterraformhubacr"
    admin_enabled                 = true
    sku                           = "Premium"
    public_network_access_enabled = false
    quarantine_policy_enabled     = false
    zone_redundancy_enabled       = false
  }

  retention_policy = {
    days    = 10
    enabled = true
  }

  enable_content_trust = true
}

module "acr" {
  source = "git::https://github.com/OmerBrumer/module-acr.git?ref=dev"

  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  subnet_id           = module.hub_vnet.subnet_ids[local.endpoint_subnet_name]
  container_registry_config = {
    name                      = local.container_registry_config.name
    admin_enabled             = local.container_registry_config.admin_enabled
    sku                       = local.container_registry_config.sku
    quarantine_policy_enabled = local.container_registry_config.quarantine_policy_enabled
    zone_redundancy_enabled   = local.container_registry_config.zone_redundancy_enabled
  }

  retention_policy = {
    days    = local.retention_policy.days
    enabled = local.retention_policy.enabled
  }

  enable_content_trust       = local.enable_content_trust
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id
  private_dns_zone_ids = [
    module.acr_private_dns_zone.id
  ]

  depends_on = [
    module.acr_private_dns_zone
  ]
}