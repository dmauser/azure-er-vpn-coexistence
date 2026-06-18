# One Ubuntu 22.04 LTS VM per VNet (hub + 2 spokes).
# NIC names match deploy.azcli references: ${vnet}-lxvm-nic
# Image matches bicep/modules/vm.bicep: Canonical / 0001-com-ubuntu-server-jammy / 22_04-lts-gen2

# ---------------------------------------------------------------------------
# Hub VM
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "hub_vm" {
  name                = "${var.hub_name}-lxvm-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.hub_subnet1.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "hub" {
  name                            = "${var.hub_name}-lxvm"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.vm_size
  admin_username                  = var.vm_admin_username
  admin_password                  = var.vm_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.hub_vm.id]
  # Cloud-init installs network tools via apt using Azure default outbound access; no VM public IP is required.
  custom_data = base64encode(local.nettools_cloud_init)
  tags        = local.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # boot_diagnostics enables Serial Console access (az serialconsole / portal).
  boot_diagnostics {}
}

# ---------------------------------------------------------------------------
# Spoke 1 VM
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "spoke1_vm" {
  name                = "${var.spoke1_name}-lxvm-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.spoke1_subnet1.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "spoke1" {
  name                            = "${var.spoke1_name}-lxvm"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.vm_size
  admin_username                  = var.vm_admin_username
  admin_password                  = var.vm_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.spoke1_vm.id]
  custom_data                     = base64encode(local.nettools_cloud_init)
  tags                            = local.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {}
}

# ---------------------------------------------------------------------------
# Spoke 2 VM
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "spoke2_vm" {
  name                = "${var.spoke2_name}-lxvm-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.spoke2_subnet1.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "spoke2" {
  name                            = "${var.spoke2_name}-lxvm"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.vm_size
  admin_username                  = var.vm_admin_username
  admin_password                  = var.vm_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.spoke2_vm.id]
  custom_data                     = base64encode(local.nettools_cloud_init)
  tags                            = local.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {}
}
