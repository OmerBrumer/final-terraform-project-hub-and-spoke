locals {
  monitorspoke_prefix = "brumer-final-terraform-monitorspoke"
}

#//////////////////////////////////Resource_Group/////////////////////////////////////////////
resource "azurerm_resource_group" "monitorspoke" {
  name     = "${local.monitorspoke_prefix}-rg"
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
  monitorspoke_route_table_name = "${local.monitorspoke_prefix}-hub-routetable"
  monitorspoke_route_table_template_variables = {
    monitorspoke_main_subnet_address_prefix = module.ipam.monitorspoke_main_subnet_address_prefix
    firewall_private_ip_address             = module.ipam.firewall_private_ip_address
  }
}

module "monitorspoke_route_table" {
  source = "git::https://github.com/OmerBrumer/module-route-table.git?ref=dev"

  route_table_name    = local.monitorspoke_route_table_name
  resource_group_name = azurerm_resource_group.monitorspoke.name
  location            = azurerm_resource_group.monitorspoke.location
  route_tables        = jsondecode(templatefile("./routes/monitorspoke_routes.json", local.monitorspoke_route_table_template_variables))

  depends_on = [
    azurerm_resource_group.monitorspoke
  ]
}

#//////////////////////////////////Network_Security_Group/////////////////////////////////////////////
locals {
  monitorspoke_nsg_name = "${local.monitorspoke_prefix}-nsg"
  monitorspoke_subnet_nsg_template_variables = {
    vpn_gateway_subnet_adress_prefix        = module.ipam.vpn_gateway_subnet_adress_prefix
    hub_subnet_address_prefix               = module.ipam.hub_subnet_address_prefix
    workspoke_main_subnet_address_prefix    = module.ipam.workspoke_main_subnet_address_prefix
    monitorspoke_main_subnet_address_prefix = module.ipam.monitorspoke_main_subnet_address_prefix
    firewall_private_ip_address             = module.ipam.firewall_private_ip_address
  }
}

module "monitorspoke_nsg" {
  source = "git::https://github.com/OmerBrumer/module-network-security-group.git?ref=dev"

  network_security_group_name = local.monitorspoke_nsg_name
  resource_group_name         = azurerm_resource_group.monitorspoke.name
  location                    = azurerm_resource_group.monitorspoke.location
  network_security_rules      = jsondecode(templatefile("./nsg_rules/monitorspoke_nsg_rules.json", local.monitorspoke_subnet_nsg_template_variables))
  log_analytics_workspace_id  = azurerm_log_analytics_workspace.hub.id

  depends_on = [
    azurerm_resource_group.monitorspoke
  ]
}

#//////////////////////////////////Virtual_Network/////////////////////////////////////////////
locals {
  monitorspoke_vnet_name   = "${local.monitorspoke_prefix}-vnet"
  monitorspoke_subnet_name = "MainSubnet"
}

module "monitorspoke_vnet" {
  source = "git::https://github.com/OmerBrumer/module-virtual-network.git?ref=dev"

  vnet_name           = local.monitorspoke_vnet_name
  resource_group_name = azurerm_resource_group.monitorspoke.name
  location            = azurerm_resource_group.monitorspoke.location
  vnet_address_space  = module.ipam.monitorspoke_vnet_address_space
  subnets = {
    "${local.monitorspoke_subnet_name}" = {
      subnet_address_prefixes   = [module.ipam.monitorspoke_main_subnet_address_prefix]
      network_security_group_id = module.monitorspoke_nsg.id
      route_table_id            = module.monitorspoke_route_table.id
    }
  }

  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  depends_on = [
    module.monitorspoke_route_table,
    module.monitorspoke_nsg
  ]
}

#//////////////////////////////////Virtual_Machine/////////////////////////////////////////////
data "azurerm_log_analytics_workspace" "main" { # In order to use this log-analyltics for the grfana
  name                = "activity-monitor-log-workspace"
  resource_group_name = "activity-log-monitor-rg"
}

locals {
  monitorspoke_vm_name                     = "${local.monitorspoke_prefix}-vm"
  reader_role_definition_name              = "Reader"
  vm_sa_log_analytics_role_assignment      = "Log Analytics Reader"
  vm_sa_main_log_analytics_role_assignment = "Main Log Analytics Reader"
}

module "grafana_virtual_machine" {
  source = "git::https://github.com/OmerBrumer/module-virtual-machine.git?ref=dev"

  vm_name                    = local.monitorspoke_vm_name
  resource_group_name        = azurerm_resource_group.monitorspoke.name
  location                   = azurerm_resource_group.monitorspoke.location
  subnet_id                  = module.monitorspoke_vnet.subnet_ids[local.monitorspoke_subnet_name]
  computer_name              = local.computer_name
  admin_username             = local.admin_username
  admin_password             = var.admin_password
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  role_assignments = {
    "${local.vm_sa_log_analytics_role_assignment}" = {
      role_definition_name = local.reader_role_definition_name
      scope                = azurerm_log_analytics_workspace.hub.id
    },

    "${local.vm_sa_main_log_analytics_role_assignment}" = {
      role_definition_name = local.reader_role_definition_name
      scope                = data.azurerm_log_analytics_workspace.main.id
    }
  }

  depends_on = [
    module.monitorspoke_vnet
  ]
}

#//////////////////////////////////Private_DNS_Zone/////////////////////////////////////////////
locals {
  grafana_private_dns_zone_name = "${replace(local.monitorspoke_prefix, "/[\\W-]/", ".")}.private.dns.zone"
  grafana_a_record_name         = "grafana"
  ttl                           = 3600
}

module "grafana_private_dns_zone" {
  source = "git::https://github.com/OmerBrumer/module-private-dns-zone.git?ref=dev"

  private_dns_zone_name = local.grafana_private_dns_zone_name
  resource_group_name   = azurerm_resource_group.monitorspoke.name
  location              = azurerm_resource_group.monitorspoke.location
  virtual_network_links = {
    "${module.monitorspoke_vnet.name}-link" = {
      virtual_network_id = module.monitorspoke_vnet.id
    }
  }

  a_records = {
    "${local.grafana_a_record_name}" = {
      records = [module.grafana_virtual_machine.nic_private_ip]
      ttl     = local.ttl
    }
  }

  depends_on = [
    module.grafana_virtual_machine
  ]
}