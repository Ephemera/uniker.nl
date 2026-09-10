---
title: Aussi, a OCI-compatible runtime for Solo5
description: How to deploy your unikernels with Docker
---

When it comes to integrating unikernels into an existing infrastructure, one of
the entry points our co-operative offers is an OCI runtime for Solo5:
[aussi][aussi]. This is an OCaml program that allows you to launch unikernels
using `solo5-hvt`. There are other solutions, such as [`urunc`][urunc], but
`aussi` is slightly better suited to Solo5 and to handling the unikernel’s
arguments.

To demonstrate the usefulness of `aussi`, we’ll start by installing
[Docker][docker]. We recommend that you follow [the documentation][docker-doc]
to get Docker set up on your machine.

```shell
$ sudo apt install docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

Then, you can install `aussi` from our co-operative's `apt` repository.

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
$ apt install solo5 aussi
```

We will then use our [immuable][immuable] unikernel as an example to explain
how to deploy a unikernel using `aussi`/Docker. So let's start by creating a
**Dockerfile** that describes how to build our `immutable` unikernel.

## The Dockerfile

:::annotate

Let's start by getting a version of OPAM from the Ubuntu system.

```Dockerfile
FROM ocaml/opam:ubuntu AS builder
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
  pkg-config m4 build-essential libgmp-dev libseccomp-dev && \
  rm -rf /var/lib/apt/lists/*
```

Let's use last version of `opam`.

```Dockerfile
RUN /bin/sh -c "ln -f /usr/bin/opam-dev /usr/bin/opam"
USER opam
RUN opam init --reinit --bare --disable-sandboxing -y
WORKDIR /home/opam
```

Let's make sure we're up to date with the latest packages available from
`opam-repository`.

```Dockerfile
RUN opam repository add git+https://github.com/ocaml/opam-repository.git
RUN opam update && opam install -y solo5 ocaml-solo5
RUN git clone https://github.com/dinosaure/immuable immuable
RUN cd immuable
WORKDIR /home/opam/immuable
```

And here, we install dependencies and build `immuable`.

```Dockerfile
RUN opam pin add -yn immuable .
RUN opam install immuable --deps-only
RUN opam exec -- make all
```

:::

At this stage, we should have an `immuable.hvt` image available, which
corresponds to our unikernel. We also have the `immuable` tool, which allows us
to create archives from a given folder. So we're going to create such a folder
containing a single file:

```shell
$ mkdir _site
$ cat >_site/index.html<<EOF
<h1>Hello World!</h1>
EOF
```

We will then extend our **Dockerfile** so that it generates the archive:

:::annotate

We'll go back to the system that enabled us to build our unikernel and our
executable.

```Dockerfile
FROM ocaml/opam:ubuntu AS packer
USER opam
WORKDIR /home/opam
COPY --from=builder /home/opam/immuable/immuable.exe /usr/bin/immuable
COPY _site /home/opam/_site
```

And we generate our archive from our `_site` folder.

```Dockerfile
RUN immuable -q -o pack.pack _site
```

:::

## The Solo5 configuration

We'll need to create one final file that corresponds to the Solo5/`aussi`
configuration in order to launch our unikernel: the **solo5.conf** file.

:::annotate

```json
{
  "version": 1,
  "type": "solo5.config",
  "mem": 128,
```

We can see the various devices required by our unikernel, namely the network
device `service` and the block device `immuable`.

As regards the network device, we are using [Docker's IPAM][ipam] here so that
Docker itself assigns us an IP address. There are other ways for a unikernel to
obtain an IP address (such as DHCP), but let's make the most of what Docker has
to offer.

```json
  "nets": {
    "service": { "type": "docker", "iface": "eth0" }
  },
  "blocks": {
    "immuable": { "path": "pack.pack", "sector-size": 512 }
  },
```

Finally, we assign the correct arguments to our unikernel, such as its IP
address provided by Docker.

```json
  "argv": [
    "--ipv4=%{solo5.net.service.ip}",
    "--ipv4-gateway=%{solo5.net.service.gw}",
    "--color=always"
  ]
}
```

:::

We're going to extend our **Dockerfile** one last time so that we have all the
artefacts needed to run our service (our unikernel and our archive).

```Dockerfile
FROM scratch
COPY --from=builder /home/opam/immuable/immuable.hvt /immuable.hvt
COPY --from=packer /home/opam/pack.pack /pack.pack
COPY solo5.json /solo5.json
ENTRYPOINT ["/immuable.hvt"]
```

## How to launch an unikernel via Docker

We can now start our unikernel using this command:

```shell
$ id=$(docker run -d --runtime=solo5 -p 9090:80/tcp immuable)
$ curl http://localhost:9090/
<h1>Hello World!</h1>
$ docker stop $id
```

You now know the basics about `aussi` and how to deploy Solo5 unikernels using
this runtime. We've used Docker and `immuable` as examples, but not only can
you deploy other unikernels with `aussi`, you can also use alternatives such as
[Podman][podman]. For further details, please refer to the `aussi`
[documentation][aussi-doc].

[aussi]: https://github.com/robur-coop/aussi
[urunc]: https://urunc.io/
[docker-doc]: https://docs.docker.com/engine/install/debian/
[docker]: https://www.docker.com/
[immuable]: /unikernels/immuable/
[ipam]: https://docs.docker.com/engine/network/
[aussi-doc]: /packages/aussi
[podman]: https://podman.io/
