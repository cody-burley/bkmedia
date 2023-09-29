Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/bionic64"

  # Defining clients
  config.vm.define "client1" do |server|
      server.vm.hostname = "client1"
      server.vm.network "private_network", ip: "172.16.82.148"
      server.vm.network "forwarded_port", guest: 22, host: 2200, id: "ssh"

      # Creating backup directory 
      server.vm.provision "shell", inline: <<-SHELL
        mkdir -p /home/vagrant/backups
        chown vagrant:vagrant /home/vagrant/backups
        chmod 755 /home/vagrant/backups
      SHELL
  end

  config.vm.define "client2" do |server|
      server.vm.hostname = "client2"
      server.vm.network "private_network", ip: "172.16.82.149"
      server.vm.network "forwarded_port", guest: 22, host: 2233, id: "ssh"

      # Creating backup directory 
      server.vm.provision "shell", inline: <<-SHELL
        mkdir -p /home/vagrant/backups
        chown vagrant:vagrant /home/vagrant/backups
        chmod 755 /home/vagrant/backups
      SHELL
  end

  # Defining main media backup server
  config.vm.define "server" do |server|
    server.vm.hostname = "server"
    server.vm.network "private_network", ip: "172.16.82.147"
    server.vm.network "forwarded_port", guest: 22, host: 2222, id: "ssh"

    # Provisioning a backup folder
    server.vm.provision "shell", inline: <<-SHELL
      mkdir -p /home/vagrant/backups
      chown vagrant:vagrant /home/vagrant/backups
      chmod 755 /home/vagrant/backups
    SHELL
  end
end