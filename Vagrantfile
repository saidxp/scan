# Gateway VM connecting two LANs (subnet A and subnet B) to the WAN (NAT) <!()!>

Vagrant.configure("2") do |config|
  
  config.vm.box = "debian13-local"
  # ---------------------------------------------------------
  # Gateway: 3 cards
  #   NIC 1 -> WAN (NAT)          -> enp0s3
  #   NIC 2 -> subnet A (cable)   -> enp0s8
  #   NIC 3 -> subnet B (cable)   -> enp0s9
  # ---------------------------------------------------------
  
  config.vm.define "gateway" do |gateway|
    gateway.vm.network "forwarded_port", guest: 22, host: 2022, host_ip: "127.0.0.1", id: "bastion-ssh"
    gateway.vm.provider "virtualbox" do |vb|
      vb.name = "remote-gateway"
      vb.memory = 1024

      # NIC 1 -> WAN
      vb.customize ["modifyvm", :id, "--nic1", "nat"]

      # NIC 2 -> subnet A
      vb.customize ["modifyvm", :id, "--nic2", "intnet"]
      vb.customize ["modifyvm", :id, "--intnet2", "gateway-lan"]

      # NIC 3 -> subnet B
      vb.customize ["modifyvm", :id, "--nic3", "intnet"]
      vb.customize ["modifyvm", :id, "--intnet3", "gateway-lan-b"]

    end
    gateway.vm.provision "shell", path: "provision/provision.sh"
    gateway.vm.provision "shell", path: "provision/gateway.sh"
    gateway.vm.provision "shell", path: "provision/dhcp.sh"
    gateway.vm.provision "shell", path: "provision/dns.sh" 
    gateway.vm.provision "shell", path: "provision/bastion.sh", args: "bastion"
    gateway.vm.provision "shell", path: "provision/logging.sh", args: "client 192.168.50.20"
  end

  # ---------------------------------------------------------
  # Client 1: subnet A (gets its IP by DHCP)
  # ---------------------------------------------------------
  config.vm.define "client1" do |client|
    client.vm.provider "virtualbox" do |vb|
      vb.name = "remote-client1"
      vb.memory = 512

      # NIC 1 -> NAT (Vagrant SSH)
      vb.customize ["modifyvm", :id, "--nic1", "nat"]

      # NIC 2 -> same cable as the gateway's subnet A card
      vb.customize ["modifyvm", :id, "--nic2", "intnet"]
      vb.customize ["modifyvm", :id, "--intnet2", "gateway-lan"]
      vb.customize ["modifyvm", :id, "--macaddress2", "080027AA0001"]

    end
    client.vm.provision "shell", path: "provision/provision.sh"
    client.vm.provision "shell", path: "provision/client.sh"
    client.vm.provision "shell", path: "provision/logging.sh", args: "client 192.168.50.20"
    client.vm.provision "shell", inline: "echo rebooting to apply dhcpcd settings", reboot: true
    # Last: closes direct SSH from the host NAT card, so the bastion is the only way in.
    client.vm.provision "shell", path: "provision/bastion.sh", args: "internal 192.168.50.1"
  end

  # ---------------------------------------------------------
  # Client 2: subnet B (static IP)
  # ---------------------------------------------------------
  config.vm.define "client2" do |client|
    client.vm.provider "virtualbox" do |vb|
      vb.name = "remote-client2"
      vb.memory = 512

      # NIC 1 -> NAT (Vagrant SSH)
      vb.customize ["modifyvm", :id, "--nic1", "nat"]

      # NIC 2 -> same cable as the gateway's subnet B card
      vb.customize ["modifyvm", :id, "--nic2", "intnet"]
      vb.customize ["modifyvm", :id, "--intnet2", "gateway-lan-b"]
    end

    client.vm.provision "shell", path: "provision/provision.sh"
    client.vm.provision "shell", path: "provision/client-b.sh"
    client.vm.provision "shell", path: "provision/logging.sh", args: "client 192.168.50.20"
    # Last: closes direct SSH from the host NAT card, so the bastion is the only way in.
    client.vm.provision "shell", path: "provision/bastion.sh", args: "internal 192.168.60.1"
  end

  # ---------------------------------------------------------
  # Loghost: dedicated centralized log server (subnet A, static)
  # ---------------------------------------------------------
  config.vm.define "loghost" do |log|
    log.vm.provider "virtualbox" do |vb|
      vb.name = "remote-loghost"
      vb.memory = 512
      vb.customize ["modifyvm", :id, "--nic1", "nat"]
      vb.customize ["modifyvm", :id, "--nic2", "intnet"]
      vb.customize ["modifyvm", :id, "--intnet2", "gateway-lan"]
    end
    log.vm.provision "shell", path: "provision/provision.sh"
    log.vm.provision "shell", path: "provision/logging.sh", args: "server 192.168.50.20"
    log.vm.provision "shell", path: "provision/bastion.sh", args: "internal 192.168.50.1"
  end

  # ---------------------------------------------------------
  # DVWA: deliberately vulnerable target (subnet B, static)
  # No host port forwards expose the web application.
  # ---------------------------------------------------------
  config.vm.define "dvwa" do |target|
    target.vm.provider "virtualbox" do |vb|
      vb.name = "scan-dvwa"
      vb.memory = 1536
      vb.customize ["modifyvm", :id, "--nic1", "nat"]
      vb.customize ["modifyvm", :id, "--nic2", "intnet"]
      vb.customize ["modifyvm", :id, "--intnet2", "gateway-lan-b"]
    end
    target.vm.provision "shell", path: "provision/dvwa.sh", args: "network"
    target.vm.provision "shell", path: "provision/provision.sh"
    target.vm.provision "shell", path: "provision/logging.sh", args: "client 192.168.50.20"
    target.vm.provision "shell", path: "provision/dvwa.sh", args: "application"
    # F2 + F3 containment: box the un-patchable web app in with the firewall.
    target.vm.provision "shell", path: "provision/dvwa.sh", args: "contain"
    # Last: closes direct SSH from the host NAT card, so the bastion is the only way in.
    target.vm.provision "shell", path: "provision/bastion.sh", args: "internal 192.168.60.1"
  end

end