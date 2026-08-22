---
title: Albatross, a service to deploy unikernels
description: How to deploy your unikernels on your server
---

At some point, you want to deploy your (or from someone else) unikernel to a
more permanent computer than your laptop. There are many ways to go this step.

We will explain how to install and use [albatross][albatross] - the
orchestration system we developed, which fits well if you have a root server or
physical machine that you control.

Albatross runs on the hypervisor and consists of multiple daemons, the core
`albatross_daemon` which is executed with superuser privileges and creates,
destroys, and supervises unikernels and their resource usage. An
`albatross-console` daemon reads the console output of each unikernel into
memory and provides an interface to observe this. The `albatross-stats` daemon
collects statistics (`getrusage`, network throughput, ..) of each unikernel.

And finally, `albatross-tls-endpoint` is used for remote access using TLS
certificates - thus your physical host can have multiple tenants who don't need
shell access.

Core concepts of Albatross are the principle of least astonishment, and least
privileges. A lot of care has been taken so that a restart of Albatross (or the
machine running Albatross) does not mean that the unikernels need to be manually
restarted.

## Installation of Albatross

For Debian and Ubuntu systems, we provide package repositories. Browse the [dists](https://apt.robur.coop/dists) folder for one matching your distribution, and add it to `/etc/apt/sources.list`:
```
$ curl -fsSL https://apt.robur.coop/gpg.pub | gpg --dearmor > /etc/apt/trusted.gpg.d/apt.robur.coop.gpg
$ cat > /etc/apt/sources.list.d/robur.sources <<END
Types: deb
URIs: https://apt.robur.coop
# change this if needed
Suites: debian-13
Components: main
Signed-By: /etc/apt/trusted.gpg.d/apt.robur.coop.gpg
END
$ apt update
$ apt install solo5 albatross
```

For FreeBSD, we as well provide binary packages at [pkg.robur.coop](https://pkg.robur.coop).

## Configuration

The binary packages install systemd (and rc.d) scripts to run Albatross. There's not much need for configuration in `albatross_daemon`, neither for `albatross_console`. The `albatross_stats` can report metrics to Influx using the `--metrics <IP:[PORT]>` argument.

## Run your first unikernel with Albatross

Once `albatross-daemon` and `albatross-console` are running, download a hello-world unikernel (from [our reproducible build server](https://builds.robur.coop/job/hello)).

Now, use `albatross-client create hello hello.hvt` to run it. You can see the output via `albatross-client console hello`.

## Network configuration

For allowing your unikernels to access the network, depending on your setup, you will have to do some work. Namely you first need a (or multiple) virtual network switch (called "bridge") where Albatross will plug in virtual cables (called "tap").

We will create a "bridge" named "service" in the IP range 10.0.42.1/24 in the following. On Linux, you configure this via `/etc/network/interfaces`:
```
auto service
# Host-only bridge
iface service inet manual
    up ip link add service-master address 02:00:00:00:00:01 type dummy
    up ip link set dev service-master up
    up ip link add service type bridge
    up ip link set dev service-master master service
    up ip addr add 10.0.42.1/24 dev service
    up ip link set dev service up
    down ip link del service
    down ip link del service-master
```

Furthermore, depending on your setup, your unikernels may need Internet connectivity and/or being accessible from the Internet.

### Single IP address available

Considering you have only on IP address available, you can setup NAT - which solves the former - as follows:
```
$ echo "1" > /proc/sys/net/ipv4/ip_forward # enables IP forwarding
$ iptables -t nat -A POSTROUTING -o enp0s20f0 -j MASQUERADE # replace enp0s20f0 with your network interface
```

To achieve the former, you need to do port forwarding:
```
iptables -A PREROUTING -t nat -p tcp -i enp0s20f0 --dport 80 -j DNAT --to-destination 10.0.42.2:80
iptables -A POSTROUTING -t nat -p tcp -d 10.0.42.2 --dport 80 -j MASQUERADE
```

### Multiple IP addresses available

You can add your physical network device to the "service" bridge, and use public IP addresses for your unikernels.

On Linux, add `up ip link set dev enp0s20f0 master service` in `/etc/network/interfaces` (replace enp0s20f0 with your ethernet interface).

## Setup your first networking unikernel

Run `albatross-client create network --net service network.hvt --arg='--ipv4=10.0.42.2/24' --arg='--ipv4-gateway=10.0.42.1'` to create your network unikernel. Thereafter, you can access `http://your-server-ip/` to see the service on port 80.
