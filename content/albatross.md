---
title: Albatross, a service to deploy unikernels
description: How to deploy your unikernels on your server
---

At some point, you want to deploy your (or from someone else) unikernel to a
more permanent computer than your laptop. There are many ways to go this step.

We will explain how to install and use
[albatross](https://github.com/robur-coop/albatross) - the orchestration system
we developed, which fits well if you have a root server or physical machine
that you control.

Albatross runs on the hypervisor and consists of multiple daemons, the core
`albatross_daemon` which is executed with superuser privileges and creates,
destroys, and supervises unikernels and their resource usage. An
`albatross-console` daemon reads the console output of each unikernel into
memory and provides an interface to observe this. The `albatross-stats` daemon
collects statistics (`getrusage`, network throughput, etc.) of each unikernel.

And finally, `albatross-tls-endpoint` is used for remote access using TLS
certificates - thus your physical host can have multiple tenants who don't need
shell access.

Core concepts of Albatross are the principle of least astonishment, and least
privileges. A lot of care has been taken so that a restart of Albatross (or the
machine running Albatross) does not mean that the unikernels need to be manually
restarted. Albatross will automatically create the virtual network cables (also
called "tap" devices) for the unikernels, and destroy them when the unikernels
have exited.

## Installation of Albatross

For Debian and Ubuntu systems, we provide package repositories. Browse the
[dists](https://apt.robur.coop/dists) folder for one matching your
distribution, and add it to `/etc/apt/sources.list`:

```shell
$ curl -fsSL https://apt.robur.coop/gpg.pub \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/apt.robur.coop.gpg
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

For FreeBSD, we as well provide binary packages at
[pkg.robur.coop](https://pkg.robur.coop).

## Configuration

The binary packages install systemd (and rc.d) scripts to run Albatross.
There's not much need for configuration in `albatross_daemon`, neither for
`albatross_console`.

Later we will dive more into the `albatross_stats` daemon, which can report
metrics to InfluxDB, and `albatross_tls_endpoint`, which takes care about
remote management.

## Run your first unikernel with Albatross

Once `albatross-daemon` and `albatross-console` are running, download a
hello-world unikernel (from [our reproducible build server][hello]).

Now, use `albatross-client create hello hello.hvt` to run it. You can see the
output via `albatross-client console hello`.

## Network configuration

For allowing your unikernels to access the network, depending on your setup,
you will have to do some work. Namely you first need a (or multiple) virtual
network switch (called "bridge") where Albatross will plug in virtual cables
(called "tap").

We will create a "bridge" named "service" in the IP range 10.0.42.1/24 in the
following. On Linux, you configure this via `/etc/network/interfaces`:
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

Furthermore, depending on your setup, your unikernels may need Internet
connectivity and/or being accessible from the Internet.

### Single IP address available

Considering you have only on IP address available, you can setup NAT - which
solves the former - as follows:

:::annotate

Here, we enable IP forwarding.

```shell
$ echo "1" > /proc/sys/net/ipv4/ip_forward # enables IP forwarding
```

And here, we allow to "MASQUERADE" IP packets on your public interface `eth0`
(it may have a different name, such as `enps0s1` or `wlan0`):

```shell
$ iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

:::

To achieve the former, you need to do port forwarding:

```shell
iptables -A PREROUTING -t nat -p tcp -i eth0 --dport 80 -j DNAT \
  --to-destination 10.0.42.2:80
iptables -A POSTROUTING -t nat -p tcp -d 10.0.42.2 --dport 80 -j MASQUERADE
```

### Multiple IP addresses available

You can add your physical network device to the "service" bridge, and use
public IP addresses for your unikernels.

On Linux, add `up ip link set dev eth0 master service` in
`/etc/network/interfaces` (again, replace `eth0` with your ethernet interface).

## Setting up immuable - a unikernel serving files via HTTP

To setup [immuable][immuable], please first follow the instructions to compile
it.

Immuable requires a block device and a network device. Once you have prepared
the data (in `pack.pack`), you can use `albatross-client` to create the block
device for you:

We use the `create-block` subcommand for creating a block device.

```shell
albatross-client create-block \
  --data=pack.pack archive \
  $(du -m pack.pack|cut -f1)
```

You can check your block devices with `albatross-client block`.

As the next step, we execute the immuable unikernel:

```shell
albatross-client create immuable \
  --block archive \
  --net service \
  immuable.hvt \
  --arg='--ipv4=10.0.42.2/24' \
  --arg='--ipv4-gateway=10.0.42.1'
```

Thereafter, you can access `http://your-server-ip/` to see immuable on port 80.
You can as well observe the running unikernels with `albatross-client info`.

## Setting up annuaire - a DNS resolver

To test whether your unikernels have Internet connectivity, get and compile
[annuaire][annuaire].

Once you set them up:

```
albatross-client create pagejaune \
  --net service pagejaune.hvt \
  --arg='--ipv4=10.0.42.3/24' --arg='--ipv4-gateway=10.0.42.1' \
  --arg='--domain foo.local' --arg='--tls-lifetime 1h' --arg='--seed foo='
```

and (requiring another block device named ban):

```
albatross-client create pageblanche \
  --net service --block ban pageblanche.hvt \
  --arg='--ipv4=10.0.42.4/24' --arg='--ipv4-gateway=10.0.42.1' \
  --arg='--domain bar.local' \
  --arg="--pagejaune '10.0.42.3!foo.local!foo='" \
  --arg='--seed bar='
```

You will be able to ask `pageblanche` for DNS records: `dig robur.coop @10.0.42.4`.

## Remote management and policies

When you are privileged enough to have a own server, you may want to share your
resources with your friends. This is possible with albatross thanks to remote
management and policies.

The `albatross_tls_endpoint` can be started to listen for remote
`albatross-client` commands to create and destroy, or observe unikernels. You
can hand out certificates to other people and organizations so they can manage
their own unikernels on your server.

We first configure this daemon using a TLS certificate. We will setup our own
certificate authority for this purpose - which we will as well use to grant our
friends access with specific resource policies.

We generate a fresh CA (named "unikernels") for the server "turtle".
```
albatross-client generate --server=turtle unikernels ca.db
```

Thereafter, various files have been created - `turtle.pem` and `turtle.key` -
the certificate and private key for `albatross_tls_endpoint`, the
`unikernels.key` and `unikernels.pem` which run our CA (keep the
`unikernels.key` secure!). And a database `ca.db` recording which certificates
have been handed out.

In the `albatross_tls_endpoint` service script, configure the key
(`turtle.key`) and certificate (`turtle.pem`), and the CA certificate
(`unikernels.pem`). And start it!

As the next step, we will create a resource policy, and allow "cherry" to run 5
unikernels on turtle. A resources policy includes the number of unikernels, the
amount of memory, which CPUids someone has access to, which network bridges
someone has access to, and how much block storage they may use.

::: annotate

We create a new policy.

```shell
$ albatross-client add-policy --csr \
```

We specify which CPU are accessible.
```shell
  --cpu 0 --cpu 1
```

We allow 1024 MB of memory.
```
  --mem 1024 \
```

The network bridges "service" and "management" are accessible.
```shell
  --net service --net management \
```

The amount of block storage is 2GB (= 2048MB).
```shell
  --block 2048 \
```

The name - cherry - and that in total 5 unikernels can be deployed.
```shell
  cherry 5
```

:::

This will create two files, `cherry.csr` and `cherry.key`. The former we need
to approve with our unikernels CA:

```shell
$ albatross-client sign unikernels.pem ca.db unikernels.key cherry.csr
```

This will output the certificate, `cherry.pem`. Whoever has `cherry.pem` and
`cherry.key` can deploy unikernels to our server:

```shell
$ albatross-client create -d <server-ip> --ca cherry.pem --ca-key cherry.key \
  --server-ca unikernels.pem hello hello.hvt
```

We can also read the console output:

```shell
$ albatross-client console -d <server-ip> --ca cherry.pem --ca-key cherry.key \
  --server-ca unikernels.pem hello
```

All the commands above can be extended with `-d .. --ca .. --ca-key ..
--server-ca ..`, and will then be executed on a remote machine!

[hello]: https://builds.robur.coop/job/hello-world/build/latest/f/bin/hello.hvt
[annuaire]: https://github.com/dinosaure/annuaire
[immuable]: https://github.com/dinosaure/immuable
