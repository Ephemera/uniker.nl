---
title: How to observe an unikernel
description: Collect and see metrics
---

Unikernels have the distinctive feature of running with a certain degree of
autonomy. It may, however, be necessary to monitor these unikernels - in
particular, to know how much memory they are using, how they are utilising
their vCPUs, and also to keep an eye on network activity.

In this chapter, we will look specifically at how to install various tools for
monitoring unikernels. In this case, we will install:
- [InfluxDB][influxdb] to collect metrics
- [Telegraf][telegraf], which allows us to bridge the gap between
  `albatross_stats` and InfluxDB
- [Grafana][grafana], which allows us to visualise the metrics

Finally, we will use one of our libraries, [tally][tally], to generate slightly
more specific metrics relating to our unikernels.

## Install & configure our infrastructure

There are plenty of tutorials online on how to install and configure InfluxDB
and Telegraf correctly, but we’ll still explain how to do it here if you’re
using Debian.

:::annotate

Here, we are trying to install Telegraf as described [here][telegraf-install].

```shell
$ sudo apt update && sudo apt upgrade -y
$ sudo apt install -y curl gnupg2 apt-transport-https
$ curl --silent --location -O \
  https://repos.influxdata.com/influxdata-archive.key
$ cat influxdata-archive.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/influxdata-archive.gpg > /dev/null
$ export KEY=/etc/apt/keyrings/influxdata-archive.gpg
$ echo 'deb [signed-by=$KEY] https://repos.influxdata.com/debian stable main' \
  | sudo tee /etc/apt/sources.list.d/influxdata.list
$ sudo apt update
$ sudo apt install -y telegraf
```

Here, we’ll install InfluxDB and create a new user called `telegraf` with a
password of your choice.

```shell
$ sudo apt install -y influxdb
$ sudo systemctl enable influxdb
$ sudo systemctl start influxdb
$ influx -execute \
  "create user telegraf with password '$PASSWORD' with all privileges"
```

:::

We need to configure Telegraf to accept metrics as input (from our unikernels)
and save them as output (to our InfluxDB database). We should have a
configuration file **/etc/telegraf/telegraf.conf** that looks like this:

```ini
[[outputs.influxdb]]
  urls = ["http://127.0.0.1:8086"]
  database = "telegraf"
  username = "telegraf"
  password = "$PASSWORD"

[[inputs.socket_listener]]
  service_address = "tcp://:8094"
  keep_alive_period = "5m"
  data_format = "influx"
```

We can therefore not only start our `telegraf` service but also create our new
`metrics` bridge, which `albatross` will be able to use to connect our
unikernels to it.

```shell
$ sudo systemctl enable telegraf
$ sudo systemctl start telegraf
$ sudo ip link name metrics type bridge
$ sudo ip addr add 192.168.2.1/24 dev metrics
$ sudo ip link set metrics up
$ sudo systemctl restart albatross
```

As regards Albatross, it is entirely possible to regenerate your **ca.key** and
**ca.pem** so that they take the new bridge into account; these rights are
embedded in the certificate issued.

In this example, we will mainly be using Tally with `solo5-hvt`, but please
note that Albatross can also collect metrics (those that the host system can
obtain by monitoring the unikernel). If you are interested in this, you can
also configure and run `albatross_stats`.

## How to monitor an unikernel

Quite simply, Tally allows you to create a _net_ device for sending metrics to
a `telegraf` server. Here is a code example that collects metrics from the
Garbage Collector, which a background task will then send:

:::annotate

```ocaml
module RNG = Mirage_crypto_rng.Fortuna

let rng () = Mirage_crypto_rng_mkernel.initialize (module RNG)
let rng = Mkernel.map rng [] |> Mkernel.finally Mirage_crypto_rng_mkernel.kill
let _5m = 300_000_000_000

let run _ metrics =
  Mkernel.run [ rng; metrics ] @@ fun _rng _metrics ->
  let rec go () =
    Mkernel.sleep _5m;
    let arr = Array.make 10_000 0 in
    for i = 0 to Array.length arr do
      Array.set arr i i
    done;
    print_endline "Hello World!";
    go ()  in
  let prm = Miou.async go in
  Miou.await_exn prm

open Cmdliner

let docs_metrics = "METRICS"
```

This option allows us to say that `mnet` can be configured over the network
using a DHCP server. As far as metrics are concerned, it may be more convenient
to let a server handle the allocation of IP addresses than to do it manually,
as we are about to do.

```ocaml
let metrics_ipv4 =
  let doc =
    "The IPv4 address (with its prefix) of the metrics interface. If it is \
     not specified (and a metrics destination is given), the metrics \
     interface is configured via a DHCP server." in
  let address = Arg.conv Ipaddr.V4.Prefix.(of_string, pp) in
  let open Arg in
  value
  & opt (some address) None
  & info [ "metrics-ipv4" ] ~doc ~docs:docs_metrics ~docv:"ADDRESS"

let metrics_ipv4_gateway =
  let doc = "The IPv4 gateway of the metrics interface." in
  let address = Arg.conv Ipaddr.V4.(of_string, pp) in
  let open Arg in
  value
  & opt (some address) None
  & info [ "metrics-ipv4-gateway" ] ~doc ~docs:docs_metrics ~docv:"IPADDR"

```

Our unikernel can communicate with our `telegraf` server via the bridge we have
created. Its destination will be `192.168.2.1:8094`, which is the IP address of
our bridge.

```ocaml
let metrics =
  let doc =
    "The address of the Telegraf server which collects metrics. If it is not \
     specified, metrics are not reported." in
  let pp ppf (ipaddr, port) = Fmt.pf ppf "%a:%d" Ipaddr.pp ipaddr port in
  let address = Arg.conv (Ipaddr.with_port_of_string ~default:8094, pp) in
  let open Arg in
  value
  & opt (some address) Non
  & info [ "metrics" ] ~doc ~docs:docs_metrics ~docv:"TELEGRAF"
```

The name of the unikernel is important because it is this value that will
enable us to filter metrics in relation to other unikernels that may exist (and
which may also generate metrics). It should also be noted that Albatross can
automatically add the `--name` option when creating a unikernel.

```ocaml
let name =
  let doc = "The name of the unikernel." in
  let open Arg in
  value
  & opt string "my-unikernel"
  & info [ "name" ] ~doc ~docs:docs_metrics ~docv:"NAME"
```

This is where we combine all our options to then create our _tally_ device.
This is also where we specify that the net interface we need will be called
`metrics`.

```ocaml
let setup_metrics ipv4 gateway dst name =
  let cfg = Option.map (fun ipv4 -> (ipv4, gateway)) ipv4 in
  let dst, port = match dst with
    | Some (dst, port) -> (Some dst, Some port)
    | None -> (None, None) in
  Tally_mnet.device ~device:"metrics" ~name cfg ?port dst

let setup_metrics =
  let open Term in
  const setup_metrics
  $ metrics_ipv4
  $ metrics_ipv4_gateway
  $ metrics
  $ name

let term =
  let open Term in
  const run
  $ Mnet_cli.setup_logs
  $ setup_metrics

let cmd =
  let info = Cmd.info "my-unikernel" in
  Cmd.v info term

let () = Cmd.(exit @@ eval cmd)
```

:::

We can now work out the dependencies, download them and compile our unikernel,
and then run it:

:::annotate

If you'd like more details on the workflow, you can go back to our tutorial to
find out how to build unikernels.

```shell
$ opam install -y tally-mnet mirage-crypto-rng-mkernel
$ unic infer -r . --prefer digestif.c -o _mfetch
$ mfetch -q
$ dune build
```

Here, we assume that your `metrics` bridge exists. We then need to create the
necessary tap interface. It is quite common to have two interfaces: one for the
service itself and the other for the metrics. It should also be noted that it
is Albatross's role to create these interfaces.

```shell
$ sudo ip tuntap add name tap0 mode tap
$ sudo ip link set tap0 master metrics
$ sudp ip link set tap0 up
```

Your firewall may sometimes block connections between the unikernel and
`telegraf`; here is a rule that allows the unikernel to send its metrics.

```shell
$ sudo iptables -I INPUT -i metrics -p tcp --dport 8094 -j ACCEPT
```

And now we can boot the unikernel!

```shell
$ solo5-hvt --net:metrics=tap0 -- _build/solo5/main.exe \
  --metrics-ipv4=192.168.2.2/24 \
  --metrics=192.168.2.1 \
  --name "my-unikernel"
```

:::

We can now examine the metrics. So we'll connect to `influx` to see what our
unikernel is adding.

```shell
$ influx -username telegraf -password $PASSWORD
> use telegraf
> SELECT * FROM gc LIMIT 10
name: gc
 compactions forced_major_collections fragments free_words heap_words host live_blocks live_stacks_words live_words major_collections minor_collections stack_size top_heap_words vm
 ----------- ------------------------ --------- ---------- ---------- ---- ----------- ----------------- ---------- ----------------- ----------------- ---------- -------------- --
  0           0                        0         0          0          foo  0           5848              0          0                 0                 19         0              my-unikernel
  0           0                        901       79903      127598     foo  4992        5848              46794      0                 2                 19         127598         my-unikernel
  0           0                        1141      82640      135790     foo  5837        5848              52009      0                 5                 19         135790         my-unikernel
  0           0                        1284      78869      135790     foo  6439        5848              55637      0                 7                 19         135790         my-unikernel
  0           0                        1431      79322      139886     foo  7004        5848              59133      0                 9                 19         139886         my-unikernel
  0           0                        1665      82179      148078     foo  7828        5848              64234      0                 12                19         148078         my-unikernel
  0           0                        1808      78671      148078     foo  8354        5848              67599      0                 14                19         148078         my-unikernel
  0           0                        1971      83537      156270     foo  8829        5848              70762      0                 16                19         156270         my-unikernel
  0           0                        2180      78279      156270     foo  9616        5848              75811      1                 19                19         156270         my-unikernel
  0           0                        2256      90255      160366     foo  7241        5848              67855      1                 21                19         160366         my-unikernel
```

As you can see, Influx retrieves the data from our unikernel `my-unikernel`. We
can now take it to the next level with [Grafana][grafana].

## Show metrics with Grafana

Here are the steps for installing Grafana; they are taken from the official
website, which can be found [here][grafana-tutorial].

```shell
$ sudo wget -O /etc/apt/keyrings/grafana.asc \
  https://apt.grafana.com/gpg-full.key
$ sudo chmod 644 /etc/apt/keyrings/grafana.asc
$ export KEY=/etc/apt/keyrings/grafana.asc
$ echo "deb [signed-by=$KEY] https://apt.grafana.com stable main" \
  | sudo tee -a /etc/apt/sources.list.d/grafana.list
$ sudo apt update
$ sudo apt install grafana 
$ sudo systemctl enable grafana-server
$ sudo systemctl start grafana-server
```

You can log in to `http://localhost:3000/` to configure your Grafana server.
This essentially involves creating a new administrator password and specifying
a data source under `Connections -> Data sources`.

You can now import a Grafana dashboard like [this one][dashboard], which
displays the metrics in a clearer way! This is the result:

![Grafana](/static/grafana.png)

It's a fairly generic dashboard, but it displays useful information and allows
us to monitor our unikernel like a true DevOps professional. Of course, each
unikernel has its own specific characteristics when it comes to metrics.

For example, an NTP server will be able to report metrics such as its offset
relative to the sources, whereas an email server will tend to display DMARC
results. This is where Tally comes in handy, as it allows you to add any
metrics you like!

[influxdb]: https://www.influxdata.com/
[telegraf]: https://www.influxdata.com/time-series-platform/telegraf/
[grafana]: https://grafana.com/
[tally]: /packages/tally
[telegraf-install]: https://docs.influxdata.com/telegraf/v1/install/#download-and-install-telegraf
[grafana-tutorial]: https://grafana.com/docs/grafana/latest/setup-grafana/
[dashboard]: /static/grafana.json
