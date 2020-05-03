/*
Create: pulumi up
Delete: pulumi destroy
*/

import * as azure from "@pulumi/azure";
import * as pulumi from "@pulumi/pulumi";
import * as provisioners from "./provisioners";

const config = new pulumi.Config();

// Common config values used in multiple spots
const hostName = config.require("host");
const hostUser = config.require("username");
const hostPassword = config.requireSecret("password");
const resourceGroupName = config.require("resourceGroup");
const location = config.require("location");

let tags = {
    category: "iot",
    dynamic: "true",
    name: hostName,
    subcategory: "edge"
}

const network = new azure.network.VirtualNetwork("edge-network", {
    resourceGroupName,
    addressSpaces: ["10.0.0.0/16"],
    location: location,
    subnets: [{
        name: "default",
        addressPrefix: "10.0.1.0/24",
    }],
    tags: tags
});

const publicIp = new azure.network.PublicIp("edge-ip", {
    resourceGroupName,
    allocationMethod: "Dynamic",
    location: location,
    tags: tags
});

const networkInterface = new azure.network.NetworkInterface("edge-nic", {
    resourceGroupName,
    ipConfigurations: [{
        name: "edge-ip-cfg",
        subnetId: network.subnets[0].id,
        privateIpAddressAllocation: "Dynamic",
        publicIpAddressId: publicIp.id,
    }],
    location: location,
    tags: tags
});

const vm = new azure.compute.LinuxVirtualMachine(hostName, {
    resourceGroupName,
    networkInterfaceIds: [networkInterface.id],
    size: config.require("size"),
    sourceImageReference: {
        publisher: config.require("imagePublisher"),
        offer: config.require("imageOffer"),
        sku: config.require("imageSku"),
        version: "latest",
    },
    osDisk: {
        caching: "ReadWrite",
        storageAccountType: "Standard_LRS",
    },
    computerName: hostName,
    adminUsername: hostUser,
    adminPassword: hostPassword,
    disablePasswordAuthentication: false,
    location: location,
    tags: tags,
}, { customTimeouts: { create: "10m" } });

const conn = {
    host: vm.publicIpAddress,
    username: hostUser,
    password: hostPassword
};

const setupScript = `setup/${config.require("setupScript")}.sh`;
console.log(`Using setup script ${setupScript}`);

// Copy setup script to server
const cpSetupScript = new provisioners.CopyFile("setup-copy", {
    conn,
    src: setupScript,
    dest: "setup.sh",
}, { dependsOn: vm });

// Make setup script executable
const chmodSetup = new provisioners.RemoteExec("setup-chmod", {
    conn,
    command: "chmod 755 setup.sh ",
 }, { dependsOn: cpSetupScript });

const hubConn = config.requireSecret("hubConnection");

const secrets = pulumi.all({
    hubConn,
    hostPassword
});

secrets.apply(s => {
    // Run setup script to install IoT Edge and otherwise configure machine
    let command = `echo "${s.hostPassword}" | sudo -S ./setup.sh --hub "${s.hubConn}"`;
    new provisioners.RemoteExec("setup-run", {
        conn,
        command: command,
    }, { dependsOn: chmodSetup });
});

// The public IP address is not allocated until the VM is running, so wait for that
// resource to create, and then lookup the IP address again to report its public IP.
const done = pulumi.all({
    _: vm.id,
    name:
    publicIp.name,
    resourceGroupName:
    publicIp.resourceGroupName,
 });

export const ipAddress = done.apply(d => {
    let ip = azure.network.getPublicIP({
        name: d.name,
        resourceGroupName: d.resourceGroupName,
    }, { async: true }).then(ip => ip.ipAddress);

    return ip;
});

export let physicalName = vm.name;

// Get ip address, ssh
// pulumi stack output ipAddress
// ssh user@$(pulumi stack output ipAddress)
