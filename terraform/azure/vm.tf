# One Ubuntu 22.04 LTS VM per VNet (hub + 2 spokes).
# NIC names match deploy.azcli references: ${vnet}-lxvm-nic
# Image matches bicep/modules/vm.bicep: Canonical / 0001-com-ubuntu-server-jammy / 22_04-lts-gen2

# ---------------------------------------------------------------------------
# Hub VM
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "hub_vm" {
  name                = "${var.hub_name}-lxvm-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "hub_vm" {
  name                = "${var.hub_name}-lxvm-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.hub_subnet1.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.hub_vm.id
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
}

# ---------------------------------------------------------------------------
# Spoke 1 VM
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "spoke1_vm" {
  name                = "${var.spoke1_name}-lxvm-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "spoke1_vm" {
  name                = "${var.spoke1_name}-lxvm-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.spoke1_subnet1.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.spoke1_vm.id
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
}

# ---------------------------------------------------------------------------
# Spoke 2 VM
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "spoke2_vm" {
  name                = "${var.spoke2_name}-lxvm-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "spoke2_vm" {
  name                = "${var.spoke2_name}-lxvm-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.spoke2_subnet1.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.spoke2_vm.id
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
}
