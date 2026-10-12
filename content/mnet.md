---
title: Mnet, our TCP/IP stack in OCaml
description: Unikernels as services
---

This is surely one of the major differences between an executable and a
unikernel: networking. In the case of a simple executable, using the POSIX
interface, it is possible to interact with the kernel's TCP/IP stack in order
to initiate and manage TCP/IP connections. This ensures that the kernel alone
acts as the network manager (hence a suite of related tools such as the
firewall with `iptables`).

As for unikernels, they cannot access the kernel's TCP/IP stack. This is why
unikernels have their **own implementations** of the TCP/IP stack. These
implementations then use what are known as TAP interfaces to connect to the
network. A TAP interface can really be compared to an Ethernet socket.

## TAP interfaces

A TAP interface is therefore a virtual device that simulates an Ethernet port.
It is through this device that the unikernel can join a network. Here, we will
look at how to allocate and manage a TAP interface.

:::annotate

Here, we create a tap interface; it can be viewed using `ip a`.

```shell
$ sudo ip tuntap add name tap0 mode tap
$ sudo ip link set tap0 up
```

:::

Next, it is generally accepted that a TAP interface is part of a network. To do
this, we will create a virtual _bridge_ and connect our TAP interface to that
bridge. 

:::annotate

```shell
$ sudo ip link add name service type bridge
$ sudo ip link set service up
```

This is how you connect a TAP interface to a bridge.

```shell
$ sudo ip link set tap0 master service
```

:::

Finally, it may be worth setting up a local IP network and ensuring that our
bridge also acts as a router.

```shell
$ sudo ip addr add 10.0.0.1/24 dev service
```

From this point onwards, we have everything we need to deploy multiple
unikernels on the same network and communicate with them. So we're going to
start using `mnet`.

## A simple echo server

`mnet` is a library that implements the TCP/IP protocol. The TCP layer is
itself implemented by the [`utcp`][utcp] project, which was created by manually
extracting a proof of the TCP state machine from [HOL4][hol4]. The project
implements other protocols, but here we’ll focus on a fairly simple service: an
echo server. Its purpose is simply to repeat whatever is sent to it.

### A brief aside on random numbers

`mnet` is a project that sometimes requires the generation of random numbers.
Here too, our unikernel cannot use the functionality provided by the kernel
(and therefore has no access to `/dev/urandom` or `getrandom(2)`). We therefore
also need to initialise our own random number generator:

```ocaml
let ( let@ ) finally fn = Fun.protect ~finally fn

let rng =
  let fn () = Mirage_crypto_rng_mkernel.(initialize (module Pfortuna)) in
  Mkernel.map fn Mkernel.[]

let () = Mkernel.(run [ rng ]) @@ fun rng () ->
  let@ () = fun () -> Mirage_crypto_rng_mkernel.kill rng in
  Fmt.pr "%s\n%!" (Ohex.encode (Mirage_crypto_rng.generate 16))
```

### Allocate a TCP/IP stack

So we're going to not only start our random number generator but also allocate
a TCP/IP stack from a net device:

:::annotate

```ocaml
let _2s = 2_000_000_000
let ( let@ ) finally fn = Fun.protect ~finally fn
let rec forever () = Mkernel.sleep _2s; forever ()

let rng =
  let fn () = Mirage_crypto_rng_mkernel.(initialize (module Pfortuna)) in
  Mkernel.map fn Mkernel.[]

let () =
```

There are several arguments for our TCP/IP stack (including the option to use
IPv6 or to have an IP address assigned by a DHCP server). Here, we'll keep
things fairly simple and assign a static IPv4 address.

```ocaml
  let cidrv4 = Ipaddr.V4.Prefix.of_string_exn "10.0.0.2/24" in
  let stack = Mnet.stack ~name:"service" cidrv4 in
  Mkernel.(run [ rng; stack ]) @@ fun rng (stack, _tcp, _udp) () ->
  let@ () = fun () -> Mirage_crypto_rng_mkernel.kill rng in
  let@ () = fun () -> Mnet.kill stack in
```

Let's make sure our unikernel never ends.

```shell
  forever ()
```

:::

Here we see the daemon concept introduced in the chapter on Miou. It is also
worth noting that we always try to adhere to the rule of not forgetting our
tasks. Whether it is our `rng` daemon or our `stack` daemon, they initiate
background tasks that we must properly _kill_ at the end of our unikernel
(using our `let@` operator).

We can now reproduce our build by adding `mnet` and `mirage-crypto-rng-mkernel`
as new dependencies for our unikernel.

```diff
- (libraries mkernel fmt)
+ (libraries mkernel fmt mirage-crypto-rng-mkernel mnet)
```

:::annotate

We recalculate the dependencies and what needs to be sourced.

```shell
$ unic infer -r . -x vendors -x _build > _mfetch
$ mfetch
bin                              ok
cstruct                          ok
digestif                         ok
mirage-crypto                    ok
mkernel                          ok
mnet                             ok
utcp                             ok
$ dune build
```

Here, we attach our new `tap0` interface to our unikernel, where the network
device is named `"service"`.

```shell
$ solo5-hvt --net:service=tap0 -- _build/solo5/main.exe --solo5:quiet &
[1] xxx
$ PID=$!
```

And we can see that our unikernel is accessible from our network!

```shell
$ ping -c3 10.0.0.2
PING 10.0.0.2 (10.0.0.2) 56(84) bytes of data.
64 bytes from 10.0.0.2: icmp_seq=1 ttl=38 time=0.246 ms
64 bytes from 10.0.0.2: icmp_seq=2 ttl=38 time=0.157 ms
64 bytes from 10.0.0.2: icmp_seq=3 ttl=38 time=0.144 ms

--- 10.0.0.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2076ms
rtt min/avg/max/mdev = 0.144/0.182/0.246/0.045 ms
$ kill -9 $PID
[1]  + xxx killed     solo5-hvt --net:service=tap0 -- _build/solo5/main.exe
```

:::

At this stage, our unikernel can communicate with other executables (as well as
other unikernels)! So let's start implementing our service.

### Our echo server

`mnet` offers an interface very similar to the `Unix` module when it comes to
_sockets_. Users will therefore not find it too difficult to communicate via
TCP/IP. We will therefore implement an echo server, which simply involves
sending back whatever the client sends us.

:::annotate

```ocaml
let handler flow =
```

All you need to do here is simply read using `Mnet.TCP.get` and write using
`Mnet.TCP.write`.

```ocaml
  let rec go () = match Mnet.TCP.read flow with
    | Ok sstr ->
      let fn = Mnet.TCP.write flow in
      List.iter fn sstr;
      go ()
    | Error (`Eof | `Refused) -> () in
  let finally = Mnet.TCP.close in
```

You can use the `Miou.Ownership` module to ensure that the connection is closed
correctly in all situations (such as cancellation).

```ocaml
  let resource = Miou.Ownership.create ~finally flow in
  Miou.Ownership.own resource;
  let@ () = fun () -> Miou.Ownership.release resource in
  go ()

let rec clean_up orphans =
  match Miou.care orphans with
  | Some None | None -> ()
  | Some (Some prm) ->
    let _ = Miou.await prm in clean_up orphans

let () =
  let cidrv4 = Ipaddr.V4.Prefix.of_string_exn "10.0.0.2/24" in
  let stack = Mnet.stack ~name:"service" cidrv4 in
  Mkernel.(run [ rng; stack ]) @@ fun rng (stack, tcp, _udp) () ->
  let@ () = fun () -> Mirage_crypto_rng_mkernel.kill rng in
  let@ () = fun () -> Mnet.kill stack in
```

We’re going to set up our service on `10.0.0.2:123`.

```ocaml
  let listen = Mnet.TCP.listen tcp 7 in
  let kind = Mnet.TCP.direct in
  let rec go orphans =
```

Just as we saw with [Miou][miou-tutorial], we're dealing with the tasks for
clients whose projects have been completed, whilst continuing to take on new
clients.

```ocaml
    clean_up orphans;
    let flow = Mnet.TCP.accept ~kind tcp listen in
    let _ = Miou.async ~orphans @@ fun () ->
      handler flow in
    go orphans in
  go (Miou.orphans ())
```

:::

We can now test our unikernel.

:::annotate

```shell
$ dune build
$ solo5-hvt --net:service=tap0 -- _build/solo5/main.exe --solo5:quiet &
$ PID=$!
```

Here, we’re launching a `netcat` client, and we can launch several at the same
time if we wish.

```shell
$ nc -q0 10.0.0.2 7
Hello World!
Hello World!
^D
$ kill -9 $PID
```

:::

## Let's communicate with Internet

We can communicate with our unikernel, but can it communicate with us? If we’re
on the local network, yes. But if the unikernel wants to connect to the
Internet, we still need to configure our network and our kernel (we'll assume
here that the interface connected to the Internet is `wlan0`):

:::annotate

This command instructs the kernel to rewrite TCP/IP packets if their
destination is outside the local network, so that the source address of these
packets is your public IP address.

```shell
$ sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o wlan0 -j MASQUERADE
```

Next, we allow packets to be transferred between the Internet and our local
network.

```shell
$ sudo iptables -A FORWARD -i service -o wlan0 -j ACCEPT
$ sudo iptables -A FORWARD -i wlan0 -o service -m state \
  --state RELATED,ESTABLISHED -j ACCEPT
$ sudo sysctl -w net.ipv4.ip_forward=1
```

:::

### A simple HTTP client

The simplest example is to send an HTTP request to a web server. This
demonstrates that our unikernel will be able to communicate with the outside
world. We’re simply going to try to retrieve the content of our favourite
website: [https://robur.coop](https://robur.coop).

:::annotate

The `getaddrinfo` function is fairly straightforward; it explains how to
resolve a DNS record using a `Mnet_dns` instance. We will use this function
later on to show happy-eyeballs how to resolve domain names.

```ocaml
let getaddrinfo dns ty domain_name =
  match ty with
  | `A ->
    let* (_, set) = Mnet_dns.getaddrinfo dns A domain_name in
    let fn ipv4 set = Ipaddr.Set.add (Ipaddr.V4 ipv4) set in
    Ok (Ipaddr.V4.Set.fold fn set Ipaddr.Set.empty)
  | `AAAA ->
    let* (_, set) = Mnet_dns.getaddrinfo dns Aaaa domain_name in
    let fn ipv6 set = Ipaddr.Set.add (Ipaddr.V6 ipv6) set in
    Ok (Ipaddr.V6.Set.fold fn set Ipaddr.Set.empty)

let () =
  let cidrv4 = Ipaddr.V4.Prefix.of_string_exn "10.0.0.2/24" in
```

A gateway is now required to tell `mnet` which router to send our packets to if
we wish to communicate with the Internet.

```ocaml
  let gateway = Ipaddr.V4.of_string_exn "10.0.0.1" in
  let stack = Mnet.stack ~name:"service" ~gateway cidrv4 in
  Mkernel.(run [ rng; stack ]) @@ fun rng (stack, tcp, _udp) () ->
  let@ () = fun () -> Mirage_crypto_rng_mkernel.kill rng in
  let@ () = fun () -> Mnet.kill stack in
```

Happy-eyeballs is a daemon that manages TCP/IP connections. The idea behind
such a daemon is that a service may be hosted on multiple servers (and multiple
IP addresses). Happy-eyeballs will compare the connection speeds of these
servers and select the fastest one.

```ocaml
  let daemon, happy_eyeballs = Mnet_happy_eyeballs.create tcp in
  let@ () = fun () -> Mnet_happy_eyeballs.kill daemon in
```

DNS is used to resolve domain names (such as robur.coop). In particular, it
uses happy-eyeballs to connect to a _nameserver_ (by default,
[uncensoreddns.org][uncensoreddns]). The injection means that happy-eyeballs is
now not only capable of handling TCP/IP connections but also of resolving
domain names.

```ocaml
  let stack = Mnet_dns.Transport.stack udp happy_eyeballs in
  let dns = Mnet_dns.create stack in
  let@ () = fun () -> Mnet_dns.Transport.kill (Mnet_dns.transport dns) in
  Mnet_happy_eyeballs.inject happy_eyeballs (getaddrinfo dns);
  let uri = "https://robur.coop/" in
  let fn _meta _req _resp buf = function
    | Some str ->
      Buffer.add_string buf str
      buf
    | None -> buf in
```

We've instantiated everything we need to make an HTTP request - let’s get in
touch with our cooperative!

```ocaml
  let result = Mhttp_client.request ~happy_eyeballs ~fn ~uri
    (Buffer.create 0x7ff) in
  match result with
  | Ok (resp, buf) ->
    let str = Buffer.contents buf in
    Fmt.pr "@[<hov>%a@]\n%!" (Hxd_string.pp Hxd.default) str
  | Error err -> Fmt.failwith "%a" Mhttp_client.pp_error err
```

:::

This example is interesting because it shows all the steps required to make an
HTTP request. In this case, several protocols are involved:
- there is, of course, TCP/IP via `mnet`
- but there is also DNS for resolving domain names; you can see the OCaml
  implementation here: [`ocaml-dns`][ocaml-dns]
- there's also happy-eyeballs, which is a standard for connecting to a service.
  Its implementation is available here: [`happy-eyeballs`][happy-eyeballs]
- although it isn't necessarily visible, TLS is involved to encrypt the
  connections. Its implementation is available here: [`ocaml-tls`][ocaml-tls]
- And of course, there’s HTTP, the implementation of which is available here:
  [`ocaml-h1`][ocaml-h1] (its [version 2][ocaml-h2] and its integration with
  Miou and Mkernel [here][mhttp])

At this stage, you can truly consider yourself a _full-stack_ developer!

## What else can we do?

At this stage, we've achieved quite a lot. It may seem fairly straightforward
to simply make an HTTP request, but the key point here is that absolutely
everything is done in OCaml (from the Ethernet frame right through to the HTTP
parser). Our cooperative is actively working on developing formats and
protocols in OCaml, particularly so that we can use these implementations in
our unikernels. It may therefore be worth taking a look at our
[packages](/packages) at this stage to explore the OCaml unikernel ecosystem
and help you develop your own unikernel.

Of course, we've shown the most visible part, but this ultimately represents
only a fraction of our ecosystem. In this case, when it comes to protocols, we
can mention our implementation of DHCP or SSH. We also implement protocols such
as NTP and OpenVPN. We can even have a bit of fun creating our own protocol,
such as [spoke][spoke]. In short, anything is possible!

In the next part, we'll show you just how far you can go when it comes to
developing your own unikernel. However, you might also now be interested in the
deployment of unikernels - and in particular, the deployment of the ones we're
offering [here](/unikernels)! Unikernels sit at the intersection of development
(as we’ve just seen here) **and** deployment. It’s time to show you our tools,
such as [Albatross][albatross] and [Aussi][aussi]!

[miou-tutorial]: /miou-scheduler/
[ocaml-dns]: https://github.com/mirage/ocaml-dns
[happy-eyeballs]: https://github.com/robur-coop/happy-eyeballs
[ocaml-tls]: https://github.com/mirleft/ocaml-tls
[ocaml-h1]: https://github.com/robur-coop/ocaml-h1
[ocaml-h2]: https://github.com/anmonteiro/ocaml-h2
[mhttp]: https://github.com/robur-coop/mhttp
[uncensoreddns]: https://blog.uncensoreddns.org/
[spoke]: https://github.com/dinosaure/spoke
[albatross]: /packages/albatross
[aussi]: /packages/aussi
[utcp]: https://github.com/robur-coop/utcp
[hol4]: https://hol-theorem-prover.org/
