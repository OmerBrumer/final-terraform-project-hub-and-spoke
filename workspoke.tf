locals {
  workspoke_prefix = "brumer-final-terraform-workspoke"
}

#//////////////////////////////////Resource_Group/////////////////////////////////////////////
resource "azurerm_resource_group" "workspoke" {
  name     = "${local.workspoke_prefix}-rg"
  location = local.location

  lifecycle {
    ignore_changes = [
      tags
    ]
  }

  depends_on = [
    azurerm_log_analytics_workspace.hub
  ]
}

#//////////////////////////////////Route_Table/////////////////////////////////////////////
locals {
  workspoke_route_table_name = "${local.workspoke_prefix}-hub-routetable"
  workspoke_route_table_template_variables = {
    workspoke_main_subnet_address_prefix = module.ipam.workspoke_main_subnet_address_prefix
    firewall_private_ip_address          = module.ipam.firewall_private_ip_address
  }
}

module "workspoke_route_table" {
  source = "git::https://github.com/OmerBrumer/module-route-table.git?ref=dev"

  route_table_name    = local.workspoke_route_table_name
  resource_group_name = azurerm_resource_group.workspoke.name
  location            = azurerm_resource_group.workspoke.location
  route_tables        = jsondecode(templatefile("./routes/workspoke_routes.json", local.workspoke_route_table_template_variables))

  depends_on = [
    azurerm_resource_group.workspoke
  ]
}

#//////////////////////////////////Network_Security_Group/////////////////////////////////////////////
locals {
  workspoke_nsg_name = "${local.workspoke_prefix}-nsg"
  workspoke_subnet_nsg_template_variables = {
    vpn_gateway_subnet_adress_prefix        = module.ipam.vpn_gateway_subnet_adress_prefix
    hub_subnet_address_prefix               = module.ipam.hub_subnet_address_prefix
    workspoke_main_subnet_address_prefix    = module.ipam.workspoke_main_subnet_address_prefix
    monitorspoke_main_subnet_address_prefix = module.ipam.monitorspoke_main_subnet_address_prefix
    firewall_private_ip_address             = module.ipam.firewall_private_ip_address
  }
}

module "workspoke_nsg" {
  source = "git::https://github.com/OmerBrumer/module-network-security-group.git?ref=dev"

  network_security_group_name = local.workspoke_nsg_name
  resource_group_name         = azurerm_resource_group.workspoke.name
  location                    = azurerm_resource_group.workspoke.location
  network_security_rules      = jsondecode(templatefile("./nsg_rules/monitorspoke_nsg_rules.json", local.workspoke_subnet_nsg_template_variables))
  log_analytics_workspace_id  = azurerm_log_analytics_workspace.hub.id

  depends_on = [
    azurerm_resource_group.workspoke
  ]
}

#//////////////////////////////////Virtual_Network/////////////////////////////////////////////
locals {
  workspoke_vnet_name       = "${local.workspoke_prefix}-vnet"
  workspoke_subnet_name     = "MainSubnet"
  workspoke_aks_subnet_name = "AksSubnet"
}

module "workspoke_vnet" {
  source = "git::https://github.com/OmerBrumer/module-virtual-network.git?ref=dev"

  vnet_name           = local.workspoke_vnet_name
  resource_group_name = azurerm_resource_group.workspoke.name
  location            = azurerm_resource_group.workspoke.location
  vnet_address_space  = module.ipam.workspoke_vnet_address_space
  subnets = {
    "${local.workspoke_subnet_name}" = {
      subnet_address_prefixes   = [module.ipam.workspoke_main_subnet_address_prefix]
      network_security_group_id = module.workspoke_nsg.id
      route_table_id            = module.workspoke_route_table.id
    }

    "${local.workspoke_aks_subnet_name}" = {
      subnet_address_prefixes   = [module.ipam.workspoke_aks_subnet_address_prefix]
      network_security_group_id = module.workspoke_nsg.id
      route_table_id            = module.workspoke_route_table.id
    }
  }

  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  depends_on = [
    module.workspoke_route_table,
    module.workspoke_nsg
  ]
}

#//////////////////////////////////Virtual_Machine/////////////////////////////////////////////
locals {
  vm_name        = "${local.workspoke_prefix}-vm"
  computer_name  = "brumer"
  admin_username = "brumer"
}

module "workspoke_virtual_machine" {
  source = "git::https://github.com/OmerBrumer/module-virtual-machine.git?ref=dev"

  vm_name                    = local.vm_name
  resource_group_name        = azurerm_resource_group.workspoke.name
  location                   = azurerm_resource_group.workspoke.location
  subnet_id                  = module.workspoke_vnet.subnet_ids[local.workspoke_subnet_name]
  computer_name              = local.computer_name
  admin_username             = local.admin_username
  admin_password             = var.admin_password
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  depends_on = [
    module.workspoke_vnet
  ]
}

#//////////////////////////////////Storage_Account/////////////////////////////////////////////
locals {
  storage_account_name                              = "brumertfstorageaccount"
  account_tier                                      = "Standard"
  account_replication_type                          = "LRS"
  storage_account_private_endpoint_subresource_name = "blob"
}

module "storage_account" {
  source = "git::https://github.com/OmerBrumer/module-storage-account.git?ref=dev"

  storage_account_name       = local.storage_account_name
  resource_group_name        = azurerm_resource_group.workspoke.name
  location                   = azurerm_resource_group.workspoke.location
  account_tier               = local.account_tier
  account_replication_type   = local.account_replication_type
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id
  subnet_id                  = module.workspoke_vnet.subnet_ids[local.workspoke_subnet_name]
  subresource_name           = local.storage_account_private_endpoint_subresource_name

  depends_on = [
    module.workspoke_vnet
  ]
}

#//////////////////////////////////AKS_Identity/////////////////////////////////////////////
locals {
  acr_pull_role_definition_name         = "AcrPull"
  aks_user_assigned_identity            = "aks-identity"
  private_dns_zone_role_definition_name = "Private DNS Zone Contributor"
  vnet_role_definition_name             = "Network Contributor"
}

resource "azurerm_role_assignment" "aks_sai_acr_pull" {
  scope                = module.acr.id
  role_definition_name = local.acr_pull_role_definition_name
  principal_id         = module.aks.principal_id

  depends_on = [
    module.acr,
    module.aks
  ]
}

resource "azurerm_user_assigned_identity" "aks" {
  name                = local.aks_user_assigned_identity
  location            = azurerm_resource_group.workspoke.location
  resource_group_name = azurerm_resource_group.workspoke.name

  lifecycle {
    ignore_changes = [
      tags
    ]
  }

  depends_on = [
    azurerm_resource_group.workspoke
  ]
}

resource "azurerm_role_assignment" "aks_uai_private_dns_zone_contributor" {
  scope                = module.aks_private_dns_zone.id
  role_definition_name = local.private_dns_zone_role_definition_name
  principal_id         = azurerm_user_assigned_identity.aks.principal_id

  depends_on = [
    azurerm_user_assigned_identity.aks,
    module.aks_private_dns_zone
  ]
}

resource "azurerm_role_assignment" "aks_uai_vnet_network_contributor" {
  scope                = module.workspoke_vnet.id
  role_definition_name = local.vnet_role_definition_name
  principal_id         = azurerm_user_assigned_identity.aks.principal_id

  depends_on = [
    azurerm_user_assigned_identity.aks,
    module.workspoke_vnet.id
  ]
}

#//////////////////////////////////Private_DNS_Zone/////////////////////////////////////////////
locals {
  aks_private_dns_zone_name = "brumerfinalterraform.private.westeurope.azmk8s.io"
}

module "aks_private_dns_zone" {
  source = "git::https://github.com/OmerBrumer/module-private-dns-zone.git?ref=dev"

  private_dns_zone_name = local.aks_private_dns_zone_name
  resource_group_name   = azurerm_resource_group.workspoke.name
  location              = azurerm_resource_group.workspoke.location

  depends_on = [
    azurerm_resource_group.workspoke
  ]
}

#//////////////////////////////////Kubernetes_Service/////////////////////////////////////////////
locals {
  aks_name            = "${local.workspoke_prefix}-aks"
  node_resource_group = "MC-${local.workspoke_prefix}"
  service_cidr        = "192.168.0.0/16"
  docker_bridge_cidr  = "192.167.0.1/16"
  aks_network_policy  = "None"
  default_node_pool = {
    name    = "default"
    count   = 1
    vm_size = "Standard_D2_v2"
  }

  aks_network_plugin = "azure"
  identity_type      = "UserAssigned"
}

module "aks" {
  source = "git::https://github.com/OmerBrumer/module-aks.git?ref=dev"

  aks_name                   = local.aks_name
  resource_group_name        = azurerm_resource_group.workspoke.name
  location                   = azurerm_resource_group.workspoke.location
  service_cidr               = local.service_cidr
  node_resource_group        = local.node_resource_group
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id
  private_dns_zone_id        = module.aks_private_dns_zone.id
  docker_bridge_cidr         = local.docker_bridge_cidr
  aks_network_policy         = local.aks_network_policy
  default_node_pool = {
    name           = local.default_node_pool.name
    count          = local.default_node_pool.count
    vm_size        = local.default_node_pool.vm_size
    vnet_subnet_id = module.workspoke_vnet.subnet_ids[local.workspoke_aks_subnet_name]
  }

  aks_network_plugin = local.aks_network_plugin
  identity_type      = local.identity_type
  identity_ids = [
    azurerm_user_assigned_identity.aks.id
  ]

  depends_on = [
    module.aks_private_dns_zone
  ]
}