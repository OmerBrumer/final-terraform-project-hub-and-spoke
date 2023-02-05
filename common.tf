locals {
  location = "West Europe"
}

module "ipam" {
  source = "git::https://github.com/OmerBrumer/module-ipam.git?ref=dev"
}

locals {
  peer_allow_forwarded_src_traffic  = true
  peer_allow_forwarded_dest_traffic = true

  peer_allow_virtual_src_network_access  = true
  peer_allow_virtual_dest_network_access = true

  allow_gateway_src_transit  = true
  allow_gateway_dest_transit = false

  use_remote_src_gateway  = false
  use_remote_dest_gateway = true
}

module "peer_workspoke" {
  source = "git::https://github.com/OmerBrumer/module-peer.git?ref=dev"

  vnet_src_resource_group_name  = azurerm_resource_group.hub.name
  vnet_dest_resource_group_name = azurerm_resource_group.workspoke.name

  vnet_src_name  = module.hub_vnet.name
  vnet_dest_name = module.workspoke_vnet.name

  vnet_src_id  = module.hub_vnet.id
  vnet_dest_id = module.workspoke_vnet.id

  allow_forwarded_src_traffic  = local.peer_allow_forwarded_src_traffic
  allow_forwarded_dest_traffic = local.peer_allow_forwarded_dest_traffic

  allow_virtual_src_network_access  = local.peer_allow_virtual_src_network_access
  allow_virtual_dest_network_access = local.peer_allow_virtual_dest_network_access

  allow_gateway_src_transit  = local.allow_gateway_src_transit
  allow_gateway_dest_transit = local.allow_gateway_dest_transit

  use_remote_src_gateway  = local.use_remote_src_gateway
  use_remote_dest_gateway = local.use_remote_dest_gateway
}

module "peer_monitorspoke" {
  source = "git::https://github.com/OmerBrumer/module-peer.git?ref=dev"

  vnet_src_resource_group_name  = azurerm_resource_group.hub.name
  vnet_dest_resource_group_name = azurerm_resource_group.monitorspoke.name

  vnet_src_name  = module.hub_vnet.name
  vnet_dest_name = module.monitorspoke_vnet.name

  vnet_src_id  = module.hub_vnet.id
  vnet_dest_id = module.monitorspoke_vnet.id

  allow_forwarded_src_traffic  = local.peer_allow_forwarded_src_traffic
  allow_forwarded_dest_traffic = local.peer_allow_forwarded_dest_traffic

  allow_virtual_src_network_access  = local.peer_allow_virtual_src_network_access
  allow_virtual_dest_network_access = local.peer_allow_virtual_dest_network_access

  allow_gateway_src_transit  = local.allow_gateway_src_transit
  allow_gateway_dest_transit = local.allow_gateway_dest_transit

  use_remote_src_gateway  = local.use_remote_src_gateway
  use_remote_dest_gateway = local.use_remote_dest_gateway
}

