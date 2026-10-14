---
title: Reproducibilty
description: How we build unikernels
---

One of the advantages of unikernels is their distribution. Indeed, as a
unikernel is the result of a static link to all the components necessary for it
to function correctly, strictly speaking, only `solo5-hvt` is required to run
any unikernel on platforms such as Linux, FreeBSD, OpenBSD and DragonFly.

One of our tasks, therefore, has been to develop a service that builds some of
our unikernels and verifies their reproducibility. In this section of the
tutorial, we will look at what is meant by reproducibility and how to use tools
such as `orb` to verify it.

## A simple hello-world

For this example, we'll use a simple unikernel, the source code for which is
available [here][hello-world]. `orb` runs from an `opam` repository, so we'll
create one locally and add a new package called `hello-world` to it:

:::annotate

```shell
$ mkdir opam-overlays
$ cd opam-overlays
```

Creating an `opam` repository simply involves creating a folder containing the
`repo` file.

```shell
$ cat >repo<<EOF
opam-version: "2.0"
upstream: "http://localhost/opam-overlays.git"
EOF
```

So we're going to create our first package, `hello-world`.

```shell
$ mkdir -p packages/hello-world.1.0.0
$ cd packages/hello-world.1.0.0
$ cat >opam<<EOF
opam-version: "2.0"
maintainer: "dummy"
synopsis: "My first reproducible unikernel"
```

Here, we explain how to build our unikernel. This involves, first of all,
downloading the source code for some of our dependencies using `mfetch` and
building our unikernel with `dune build`, as we explained
[here][unikernel-dune].

```shell
build: [
  [ "mfetch" ]
  [ "dune" "build" ]
]
```

We can install our unikernel as well as the version with debug symbols. `strip`
allows us to remove these symbols and reduce the size of our unikernel by 2MB!

```shell
install: [
  [ "chmod" "+w" "_build/solo5/main.exe" ]
  [ "cp" "_build/solo5/main.exe" "%{bin}%/hello.hvt" ]
  [ "strip" "%{bin}%/hello.hvt" ]
  [ "cp" "_build/solo5/main.exe" "%{prefix}%/hello.hvt.debug" ]
]
depends: [
  "ocaml" {>= "5.5.0"}
  "mkernel"
  "ocaml-solo5"
```

Among the dependencies, some can be tagged with the `{build}` flag: this
ensures that updating these dependencies **does not** require our unikernel to
be recompiled.

```shell
  "dune" {>= "3.0.0" & build}
  "mfetch" {build}
  "unic" {build}
]
```

This is surely the most interesting part for `orb`.

To ensure reproducibility, you download the source code and run `mfetch lock`;
this is more or less the same as `opam lock` but for the source code you’ve
just downloaded. `mfetch` records where the source code comes from, along with
their signatures, and stores this information in a `mfetch.locked` file, which
`orb` can then use to record everything needed to build your unikernel.

```shell
x-mkernel-pre-build: [
  ["mfetch" "fetch" "--with-dune-file" "--file=_mfetch"]
  ["mfetch" "lock" "--file=_mfetch" "--output=_mfetch.locked"]
]
url { src: "git+https://git.robur.coop/robur/hello-world.git" }
EOF
```

:::

At this stage, we can add our new repository to `opam`.

```shell
$ cd -
$ opam switch create 5.5.0
$ opam repository add overlays .
$ opam repository
<><> Repository configuration for switch 5.5.0 ><><><><><><><><><><><><><><><><>
 1 overlays file:///home/$USER/opam-overlays
 4 default  https://opam.ocaml.org
```

You can now install `orb` and start using it!

:::annotate

```shell
$ mkdir reproduce
$ cd reproduce
$ opam install orb
```

First of all, we're going to build our unikernel using `orb`. It will
initialise a temporary switch and execute our instructions to build our
unikernel. Make sure that the repositories match the description provided by
`opam repository`.

```shell
$ export REPOS="default:https://opam.ocaml.org"
$ export REPOS="$REPOS,file:///home/$USER/opam-overlays"
$ orb build --repos="$REPOS" hello-world
[ORB] using root "/home/$USER/.opam" and switch "orbf14714temp"
[overlays] no changes from file:///home/$USER/dev/opam-overlays
[default] no changes from https://opam.ocaml.org
[ORB] Switch orbf14714temp created!
[ORB] installing dependencies
[ORB] Install start
[ORB] Install hello-world
The following actions will be performed:
=== install 118 packages
...
[ORB] Installed hello-world
[ORB] installed dependencies
⬇ retrieved hello-world.1.0.0  (...)
# To update the current shell environment, run: eval $(opam env)
mkernel                          ok
1 sources locked into _mfetch.locked
[ORB] now building hello-world.1.0.0
[ORB] built hello-world.1.0.0, now installing
∗ installed hello-world.1.0.0
[ORB] installed hello-world.1.0.0, now registering
[ORB] tracking map got locks
[ORB] got tracking map, dropping states
```

This is where we generate a signature for the artefacts we have just built
(namely, `hello.hvt` and `hello.debug.hvt`).

```shell
[ORB] writing /home/dinosaure/dev/reproduce/hello-world.build-hashes
[ORB] cleaning up
```

`orb` can be more sophisticated and scan for system dependencies if it is
running on a system such as Debian or FreeBSD. In this case, it does not do so
here as we are using Arch Linux, but the settings can be extended to ensure
reproducibility on the systems mentioned.

```shell
[ORB] unsupported OS for host system packages (os=linux, os-family=arch)
[ORB] Switch orbf14714temp removed
[ORB] cleaning up
```

We can start rebuilding it, but this time using the parameters we managed to
aggregate during our first build.

```shell
$ orb rebuild .
[ORB] key SWITCH_PATH not available
[ORB] environment matches
[ORB] unsupported OS for host system packages (os=linux, os-family=arch)
[ORB] Switch orbf14714temp created!
[ORB] now importing switch
The following actions will be performed:
=== install 118 packages
...
[ORB] Switch orbf14714temp imported!
[ORB] extracting sources
# To update the current shell environment, run: eval $(opam env)
⬇ retrieved hello-world.1.0.0  (...)
```

It is at this point that `orb` attempts to replicate what `mfetch` did
previously.

```shell
[ORB] found 1 x-mfetch-vendored-dirs
[ORB] downloaded 1 tarballs
[ORB] now building hello-world.1.0.0
[ORB] built hello-world.1.0.0, now installing
∗ installed hello-world.1.0.0
[ORB] installed hello-world.1.0.0, now registering
[ORB] tracking map got locks
[ORB] got tracking map, dropping states
```

We recalculate the signatures of the artefacts we have just reconstructed.

```shell
[ORB] writing /home/dinosaure/dev/reproduce/hello-world.build-hashes
[ORB] comparing with old build dir no
```

And our unikernel is reproducible!

```shell
[ORB] It is reproducible!!!
[ORB] cleaning up
[ORB] unsupported OS for host system packages (os=linux, os-family=arch)
[ORB] Switch orbf14714temp removed
```

:::

## Introspection

Although reproducibility is ensured, it depends on a context that `orb`
describes in several files:
- `build-environment`, which describes the environment variables. This file
  exists, in particular, to ensure that the build does not depend on variables
  such as `SOURCE_DATE_EPOCH`
- `system-packages`, which describes the system packages. For example, packages
  such as `ca_root_nss` may be involved in the generation of a unikernel that
  uses [`ca-certs-nss`][ca-certs-nss].
- `opam-switch`, which describes the OPAM packages required to build the
  unikernel. This is where the versions and source signatures are specified.

These files therefore describe the build context for our unikernel. In
particular, this enables us to track changes. Indeed, this context may change
over time (through updates) and may affect the final artefact. This is when we
might ask ourselves whether we can track these changes _automatically_.

## [builds.robur.coop][builds.robur.coop]

That is why we have developed [builds.robur.coop][builds.robur.coop]. It is a
service that builds a series of unikernels that we are developing and checks
their reproducibility on a daily basis. If reproducibility is no longer
guaranteed, thanks to the files provided by `orb`, we can identify which
changes to the system packages and OPAM packages have affected our artefacts.

It should be noted that not all updates necessarily affect the generated
artefact.

In this case, our hello-world unikernel is available here:

[https://builds.robur.coop/job/hello-world/build/latest][hello-world-latest]

The website and the infrastructure for building unikernels are projects
available here:
- [builder-web][builder-web], our website built using [Miou][miou] and
  [Vif][vif]
- [builder][builder], a simple daemon that schedules the building of unikernels
  and software (such as `solo5-hvt`)

[hello-world]: https://git.robur.coop/robur/hello-world
[unikernel-dune]: /unikernels-and-libraries/#workflow
[builds.robur.coop]: https://builds.robur.coop/
[ca-certs-nss]: https://github.com/mirage/ca-certs-nss
[hello-world-latest]: https://builds.robur.coop/job/hello-world/build/latest
[builder-web]: https://github.com/robur-coop/builder-web/
[miou]: /packages/miou
[vif]: /packages/vif
[builder]: https://github.com/robur-coop/builder
