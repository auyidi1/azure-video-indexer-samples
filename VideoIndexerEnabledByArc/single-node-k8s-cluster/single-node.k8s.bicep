@description('Azure Resource Name Prefux')
param prefix string

@description('Specifies control plane node VM size.')
param controlPlaneNodeVmSize string = 'Standard_DS96a_v4'

@description('Specifies the location.')
param location string = resourceGroup().location

@description('Specifies the address prefixes of the virtual network.')
param virtualNetworkAddressPrefixes string = '10.0.0.0/16'

@description('Specifies the address prefix of the subnet which contains the virtual machine.')
param vmSubnetAddressPrefix string = '10.0.1.0/24'

@description('Specifies the name of the network security group associated to the subnet hosting the virtual machine.')
param vmSubnetNsgName string = '${prefix}SubnetNsg'

var vnetName = '${prefix}vnet'
var subnetName = '${vnetName}-subnet0'
var nicName = '${prefix}nic'

var vmName = 'k8s-master'
var publicIPName = '${prefix}publicIP'

param tags object = {
  environment: 'dev'
  IaaC: 'bicep'
  user: '${prefix}-user'
}

@description('Specifies the type of authentication when accessing the Virtual Machine. SSH key is recommended.')
@allowed([
  'sshPublicKey'
  'password'
])
param authenticationType string = 'sshPublicKey'


@description('Specifies the name of the administrator account of the virtual machine.')
param vmAdminUsername string = 'azureuser'

@description('Specifies the SSH Key or password for the virtual machine. SSH key is recommended.')
@secure()
param vmAdminPasswordOrKey string 

var linuxConfiguration = {
  disablePasswordAuthentication: true
  ssh: {
    publicKeys: [
      {
        path: '/home/${vmAdminUsername}/.ssh/authorized_keys'
        keyData: vmAdminPasswordOrKey
      }
    ]
  }
  provisionVMAgent: true
}

resource vmSubnetNsg 'Microsoft.Network/networkSecurityGroups@2021-08-01' = {
  name: vmSubnetNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSshInbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          destinationPortRange: '22'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowDNSInbound'
        properties: {
          priority: 101
          access: 'Allow'
          direction: 'Inbound'
          destinationPortRange: '54'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

var vmSubnet = {
  name: subnetName
  properties: {
    addressPrefix: vmSubnetAddressPrefix
    networkSecurityGroup: {
      id: vmSubnetNsg.id
    }
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Disabled'
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2021-02-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefixes
      ]
    }
    subnets: [
      vmSubnet
    ]
  }
}

resource publicIP 'Microsoft.Network/publicIPAddresses@2020-08-01' = {
  name: publicIPName
  location: location
  properties: {
    publicIPAllocationMethod: 'Dynamic'
  }
}

resource virtualMachineNic 'Microsoft.Network/networkInterfaces@2021-08-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIP.id
          }
          subnet: {
            id: virtualNetwork.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2021-07-01' = {
  name: vmName
  tags: tags
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: controlPlaneNodeVmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPasswordOrKey
      linuxConfiguration: (authenticationType == 'password') ? null : linuxConfiguration
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-focal'
        sku: '20_04-lts-gen2'
        version: '20.04.202312080'
      }
      osDisk: {
        createOption: 'fromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    
    networkProfile: {
      networkInterfaces: [
        {
          id: virtualMachineNic.id
        }
      ]
    }
  }
}

resource vmExtensionKubeAdmInstall 'Microsoft.Compute/virtualMachines/extensions@2021-07-01' = {
  parent: virtualMachine
  name: 'customScriptExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: '''
      wget https://raw.githubusercontent.com/Azure-Samples/media-services-video-indexer/master/VideoIndexerEnabledByArc/scripts/kubeadm_install_master.sh -O /tmp/kubeadm_install_master.sh
      chmod +x /tmp/kubeadm_install_master.sh
      sudo /tmp/kubeadm_install_master.sh
      wget https://raw.githubusercontent.com/Azure-Samples/media-services-video-indexer/master/VideoIndexerEnabledByArc/scripts/vi_extension_install.sh -O /tmp/vi_extension_install.sh 
      chmod +x /tmp/vi_extension_install.sh
      '''
    }
  }
}

