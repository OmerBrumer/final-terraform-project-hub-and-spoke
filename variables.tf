variable "admin_password" {
  description = "(Optional)Admin password when ssh to the virtual machine"
  type        = string
  default     = null
}

variable "aad_tenant" {
  description = "(Optional)AAD tenant for vpn configuration"
  type        = string
  default     = null
}